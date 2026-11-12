# Tests for uc-apex-sync.sh against the fake SQLcl. Run with test/run.sh.
# Every function named test_* is a test; setup/teardown run around each.
# shellcheck shell=bash disable=SC2329,SC2034  # OUT/RC are read by the asserts in lib.sh

P1=pages/p00001-home.apx
P2=pages/p00002-customers.apx
P3=pages/p00003-orders.apx
LOV=shared-components/lovs/status.apx

# --- init -------------------------------------------------------------------

test_init_finds_the_commit_that_matches_the_db() {
  local base
  base=$(git rev-parse HEAD)
  git branch -D -q apex-db
  edit_local $P1 's/title: Home/title: Start/'
  commit_local "local work after the last export"
  run init
  assert_ok
  assert_eq "$(git rev-parse apex-db)" "$base" "apex-db base"
}

test_init_fails_when_no_commit_matches() {
  git branch -D -q apex-db
  edit_db $P1 's/title: Home/title: Changed in DB/'
  run init
  assert_fails
  assert_out "no commit on main matches"
  git rev-parse -q --verify refs/heads/apex-db >/dev/null && fail "apex-db was created"
  [ -z "$(git worktree list | sed 1d)" ] || fail "temporary worktree left behind"
}

test_init_with_explicit_commit() {
  git branch -D -q apex-db
  run init HEAD
  assert_ok
  assert_eq "$(git rev-parse apex-db)" "$(git rev-parse HEAD)"
}

test_init_refuses_existing_branch() {
  run init HEAD
  assert_fails
  assert_out "already exists"
}

# --- sync: the basic scenarios ----------------------------------------------

test_sync_with_nothing_to_do() {
  run sync -y
  assert_ok
  assert_out "nothing to import"
  assert_no_import
}

test_sync_imports_only_the_changed_file() {
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y
  assert_ok
  assert_imports "import -files $P1"
  assert_db_has $P1 "title: Start"
  assert_in_sync
}

test_sync_pulls_db_changes_without_importing() {
  edit_db $P2 's/title: Customers/title: Clients/'
  run sync -y
  assert_ok
  assert_out "DB has changes since the last sync"
  assert_out "nothing to import"
  assert_no_import
  assert_repo_has $P2 "title: Clients"
  assert_in_sync
}

test_sync_keeps_colleague_changes_in_other_files() {
  edit_db $P2 's/title: Customers/title: Clients/'
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y
  assert_ok
  assert_imports "import -files $P1"
  assert_db_has $P1 "title: Start"
  assert_db_has $P2 "title: Clients"
  assert_repo_has $P2 "title: Clients"
  assert_in_sync
}

test_sync_merges_changes_in_different_parts_of_the_same_file() {
  edit_db $P1 's/htmlCode: Home footer/htmlCode: Footer by colleague/'
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y
  assert_ok
  assert_imports "import -files $P1"
  assert_db_has $P1 "title: Start"
  assert_db_has $P1 "htmlCode: Footer by colleague"
  assert_in_sync
}

test_sync_stops_on_conflict_and_continues_after_resolving() {
  edit_db $P1 's/title: Home/title: Theirs/'
  edit_local $P1 's/title: Home/title: Ours/'
  commit_local
  run sync -y
  assert_fails
  assert_out "merge conflicts above"
  assert_out "$APP/$P1"
  assert_no_import
  assert_db_has $P1 "title: Theirs"

  # resolve: keep both
  git checkout -q --ours -- "$APP/$P1"
  edit_local $P1 's/title: Ours/title: Ours and Theirs/'
  git add -A && git commit -q --no-edit
  run sync -y
  assert_ok
  assert_db_has $P1 "title: Ours and Theirs"
  assert_in_sync
}

test_sync_twice_is_a_no_op() {
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y
  assert_ok
  : >"$FAKE_DB/log"
  run sync -y
  assert_ok
  assert_out "nothing to import"
  assert_no_import
}

# --- local changes ----------------------------------------------------------

test_sync_commits_uncommitted_app_changes_only() {
  edit_local $P1 's/title: Home/title: Start/'
  echo "unrelated" >>README.md
  run sync -y -m "my page change"
  assert_ok
  git log --format=%s | grep -q "my page change" || fail "commit message not used"
  git diff --quiet -- README.md && fail "README.md change was committed"
  assert_db_has $P1 "title: Start"
}

test_sync_without_message_uses_default_commit_message() {
  edit_local $P1 's/title: Home/title: Start/'
  run sync -y
  assert_ok
  git log --format=%s | grep -q "App changes before DB sync" || fail "default message not used"
}

# --- staleness check --------------------------------------------------------

test_sync_aborts_when_the_db_changes_after_the_export() {
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  # Session 1 is the export; before session 2 (the checksum check) a colleague
  # saves page 2 in the Builder.
  # shellcheck disable=SC2016
  export FAKE_HOOK='[ "$FAKE_CALL" = 2 ] && sed -i.bak "s/title: Customers/title: Saved meanwhile/" "$FAKE_DB/app/pages/p00002-customers.apx" && rm -f "$FAKE_DB/app/pages/p00002-customers.apx.bak"; true'
  run sync -y
  assert_fails
  assert_out "was changed in the DB since the export"
  assert_no_import
  assert_db_lacks $P1 "title: Start"

  unset FAKE_HOOK
  run sync -y
  assert_ok
  assert_db_has $P1 "title: Start"
  assert_db_has $P2 "title: Saved meanwhile"
  assert_repo_has $P2 "title: Saved meanwhile"
  assert_in_sync
}

# --- what gets imported -----------------------------------------------------

test_deleted_component_needs_full_import() {
  git rm -q "$APP/$P3"
  commit_local
  run sync -y
  assert_ok
  assert_out "partial imports cannot delete components"
  assert_imports "import full"
  [ ! -f "$FAKE_DB/app/$P3" ] || fail "page 3 still in DB"
  assert_in_sync
}

test_new_component_is_imported_partially() {
  sed 's/^page 3 (/page 4 (/; s/ORDERS/INVOICES/' "$APP/$P3" >"$APP/pages/p00004-invoices.apx"
  commit_local
  run sync -y
  assert_ok
  assert_imports "import -files pages/p00004-invoices.apx"
  assert_in_sync
}

test_static_file_change_imports_its_owner() {
  echo 'console.log("changed");' >"$APP/shared-components/static-files/app.js"
  commit_local
  run sync -y
  assert_ok
  assert_imports "import -files shared-components/static-files.apx"
  assert_db_has shared-components/static-files/app.js 'changed'
  assert_in_sync
}

test_unsupported_partial_import_falls_back_to_full() {
  echo "-- more" >>"$APP/supporting-objects/install-scripts/create-tables.sql"
  commit_local
  run sync -y
  assert_ok
  assert_out "cannot import these files on their own"
  assert_imports "import full"
  assert_db_has supporting-objects/install-scripts/create-tables.sql "-- more"
  assert_in_sync
}

test_unowned_non_apx_file_needs_full_import() {
  sed -i.bak 's/"id" : 100/"id" : 100, "x" : 1/' "$APP/deployments/default.json" && rm -f "$APP/deployments/default.json.bak"
  commit_local
  run sync -y
  assert_ok
  assert_out "does not belong to an .apx component file"
  assert_imports "import full"
}

test_full_flag_forces_full_import() {
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y --full
  assert_ok
  assert_imports "import full"
  assert_in_sync
}

test_old_apex_version_uses_full_import() {
  echo 26.1.0 >"$FAKE_DB/version"
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y
  assert_ok
  assert_out "needs 26.2+"
  assert_imports "import full"
}

# --- importing a subset -----------------------------------------------------

test_sync_with_paths_imports_only_those() {
  edit_local $P1 's/title: Home/title: Start/'
  edit_local $LOV 's/display: Open/display: Opened/'
  commit_local
  run sync -y "pages/*"
  assert_ok
  assert_imports "import -files $P1"
  assert_out "not selected, stay local"
  assert_out "$LOV"
  assert_db_lacks $LOV "display: Opened"
  assert_repo_has $LOV "display: Opened"
  git diff --quiet apex-db HEAD -- "$APP/$P1" || fail "apex-db does not record page 1"

  run status
  assert_ok
  assert_out "$LOV"
  assert_not_out "$P1"

  : >"$FAKE_DB/log"
  run sync -y
  assert_ok
  assert_imports "import -files $LOV"
  assert_in_sync
}

test_sync_with_paths_refuses_deletions() {
  git rm -q "$APP/$P3"
  commit_local
  run sync -y pages/
  assert_fails
  assert_out "cannot import only pages/"
  assert_no_import
}

test_sync_with_paths_and_nothing_changed_there() {
  edit_local $LOV 's/display: Open/display: Opened/'
  commit_local
  run sync -y pages/
  assert_ok
  assert_out "nothing to import under: pages/"
  assert_no_import
}

test_sync_with_paths_refuses_unsupported_components() {
  echo "-- more" >>"$APP/supporting-objects/install-scripts/create-tables.sql"
  commit_local
  run sync -y supporting-objects/
  assert_fails
  assert_out "nothing imported"
  assert_no_import
}

# --- errors -----------------------------------------------------------------

test_validation_errors_stop_before_import() {
  printf 'COMPILE_ERROR\n' >>"$APP/$P1"
  commit_local
  run sync -y
  assert_fails
  assert_out "validation failed"
  assert_no_import
}

test_import_errors_are_reported() {
  printf 'RUNTIME_ERROR\n' >>"$APP/$P1"
  commit_local
  run sync -y
  assert_fails
  assert_out "import reported errors"
  assert_out "ORA-20001"
}

test_export_errors_are_reported() {
  export APP_ID=999
  run sync -y
  assert_fails
  assert_out "export of app 999 from fake failed"
  assert_out "ORA-20987"
}

test_wrong_alias_folder_is_explained() {
  echo other-alias >"$FAKE_DB/alias"
  run pull
  assert_fails
  assert_out "folder name match the app alias"
}

test_refuses_other_branch() {
  git checkout -q -b feature
  run sync -y
  assert_fails
  assert_out "check out main first"
}

test_sync_branch_setting() {
  git checkout -q -b development
  export SYNC_BRANCH=development
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync -y
  assert_ok
  assert_db_has $P1 "title: Start"
}

test_refuses_staged_files_outside_the_app() {
  echo "x" >>README.md
  git add README.md
  run sync -y
  assert_fails
  assert_out "files outside $APP are staged"
}

test_refuses_without_db_branch() {
  git branch -D -q apex-db
  git worktree remove --force "$(git rev-parse --git-common-dir)/apex-db-worktree" 2>/dev/null || true
  run sync -y
  assert_fails
  assert_out "branch apex-db missing"
}

test_needs_confirmation_without_tty() {
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  run sync
  assert_fails
  assert_out "needs confirmation; run with -y"
  assert_no_import
}

test_leftovers_in_worktree_are_discarded() {
  run pull
  assert_ok
  echo "garbage" >"$(git rev-parse --git-common-dir)/apex-db-worktree/$APP/garbage.apx"
  run sync -y
  assert_ok
  assert_out "discarding leftovers"
  [ ! -f "$FAKE_DB/app/garbage.apx" ] || fail "garbage imported"
}

test_unknown_command_and_option() {
  run frobnicate
  assert_fails
  assert_out "unknown command"
  run sync --frobnicate
  assert_fails
  assert_out "unknown option"
}

# --- formatting normalized by the export ------------------------------------

test_db_formatting_wins_after_import() {
  # trailing blanks: imported as is, but the export strips them
  edit_local $P1 's/title: Home/title: Start   /'
  commit_local
  run sync -y
  assert_ok
  assert_repo_has $P1 "title: Start"
  grep -q 'title: Start   $' "$APP/$P1" && fail "trailing blanks still in repo"
  assert_in_sync
}

# --- pull / status ----------------------------------------------------------

test_pull_merges_without_touching_the_db() {
  edit_db $P2 's/title: Customers/title: Clients/'
  edit_local $P1 's/title: Home/title: Start/'
  run pull -m "wip"
  assert_ok
  assert_no_import
  assert_repo_has $P2 "title: Clients"
  assert_db_lacks $P1 "title: Start"
}

test_status_is_offline() {
  edit_local $P1 's/title: Home/title: Start/'
  commit_local
  export SQLCL=/nonexistent
  run status
  assert_ok
  assert_out "$P1"
  assert_out "import: only these files"
}

test_status_reports_uncommitted_changes() {
  edit_local $P1 's/title: Home/title: Start/'
  run status
  assert_ok
  assert_out "uncommitted changes"
}

test_help_and_version() {
  run --help
  assert_ok
  assert_out "Usage: uc-apex-sync <command>"
  run --version
  assert_ok
  assert_out "uc-apex-sync "
}

# --- example makefile -------------------------------------------------------

# Install the command like a user would: make install into a dir on the PATH.
install_cmd() {
  make -s -C "$TEST_DIR/.." install BIN_DIR="$WORK/bin" >/dev/null || fail "make install failed"
  PATH="$WORK/bin:$PATH"
  export PATH
}

test_install_symlinks_the_command() {
  install_cmd
  [ -L "$WORK/bin/uc-apex-sync" ] || fail "no symlink"
  OUT=$(uc-apex-sync --version 2>&1) RC=$?
  assert_ok
  assert_out "uc-apex-sync "
  make -s -C "$TEST_DIR/.." uninstall BIN_DIR="$WORK/bin"
  [ ! -e "$WORK/bin/uc-apex-sync" ] || fail "uninstall left the symlink"
}

test_example_makefile_uses_installed_command() {
  install_cmd
  cp "$TEST_DIR/../examples/makefile" makefile
  OUT=$(make 2>&1) RC=$?
  assert_ok
  assert_out "sync-app"
  edit_local $P1 's/title: Home/title: Start/'
  edit_local $P2 's/title: Customers/title: Clients/'
  OUT=$(make sync-status FILES=pages/p00001-home.apx 2>&1) RC=$?
  assert_ok
  assert_out "uncommitted changes"
  OUT=$(make sync-app YES=1 MSG="via make" FILES=pages/p00001-home.apx </dev/null 2>&1) RC=$?
  assert_ok
  assert_out "uc-apex-sync sync -y"
  assert_imports "import -files $P1"
  git log --format=%s | grep -q "via make" || fail "MSG not passed"
  : >"$FAKE_DB/log"
  OUT=$(make sync-app YES=1 FULL=1 </dev/null 2>&1) RC=$?
  assert_ok
  assert_imports "import full"
  OUT=$(make validate-app 2>&1) RC=$?
  assert_ok
  assert_out "Validation successful"
}

test_example_makefile_prefers_project_copy() {
  install_cmd
  cp "$TEST_DIR/../examples/makefile" makefile
  mkdir -p scripts
  cp "$SCRIPT" scripts/uc-apex-sync.sh
  git add -A && git commit -q -m "pin uc-apex-sync"
  OUT=$(make -n sync-status 2>&1) RC=$?
  assert_ok
  assert_out "./scripts/uc-apex-sync.sh status"
  assert_not_out "$WORK/bin"
}

test_example_makefile_without_command() {
  cp "$TEST_DIR/../examples/makefile" makefile
  OUT=$(PATH=/usr/bin:/bin make sync-status 2>&1) RC=$?
  assert_fails
  assert_out "uc-apex-sync not found"
}
