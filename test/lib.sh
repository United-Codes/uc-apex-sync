# Test helpers. Sourced by test/run.sh; each test runs in its own subshell
# with a fresh repo ($REPO) and a fresh fake database ($FAKE_DB).
# shellcheck shell=bash

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../uc-apex-sync.sh"
APP=src/app/demo-app

fail() {
  printf '    FAIL: %b\n' "$*" >&2
  if [ -n "${OUT:-}" ]; then
    printf '    --- last output (rc=%s) ---\n' "${RC:-?}" >&2
    sed 's/^/    | /' <<<"$OUT" >&2
  fi
  exit 1
}

# Fresh repo with the fixture app committed on main, a fake DB holding the same
# app, and the DB branch initialized.
setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/uc-apex-sync-test.XXXXXX")
  REPO="$WORK/repo"
  FAKE_DB="$WORK/db"
  export FAKE_DB
  export SQLCL="$TEST_DIR/fake-sql" DB_CONN=fake APP_ID=100 APP_DIR=$APP
  unset SYNC_BRANCH DB_BRANCH APEX_WORKSPACE MSG FAKE_HOOK
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

  mkdir -p "$FAKE_DB/app" "$REPO/$APP"
  cp -R "$TEST_DIR/fixture/demo-app/." "$FAKE_DB/app/"
  cp -R "$TEST_DIR/fixture/demo-app/." "$REPO/$APP/"
  cd "$REPO" || exit 1
  git init -q -b main
  echo "readme" >README.md
  git add -A
  git commit -q -m "initial export"
  run init
  [ "$RC" -eq 0 ] || fail "init failed in setup"
  : >"$FAKE_DB/log"
  rm -f "$FAKE_DB/calls"
}

teardown() {
  cd / && rm -rf "$WORK"
}

# run <args...>: run the script, keep output in OUT and exit code in RC
run() {
  RC=0
  OUT=$("$SCRIPT" "$@" 2>&1 </dev/null) || RC=$?
}

# Edit a file in the repo / in the DB (= a colleague saving in the Builder).
# edit <file relative to app> <sed expression>
edit_local() { sed -i.bak "$2" "$REPO/$APP/$1" && rm -f "$REPO/$APP/$1.bak"; }
edit_db() { sed -i.bak "$2" "$FAKE_DB/app/$1" && rm -f "$FAKE_DB/app/$1.bak"; }
commit_local() { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "${1:-local change}"; }

assert_ok() { [ "$RC" -eq 0 ] || fail "expected success, got rc=$RC${1:+ ($1)}"; }
assert_fails() { [ "$RC" -ne 0 ] || fail "expected failure${1:+ ($1)}"; }
assert_out() { grep -qF -- "$1" <<<"$OUT" || fail "output does not contain: $1"; }
assert_not_out() { ! grep -qF -- "$1" <<<"$OUT" || fail "output unexpectedly contains: $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"; }

assert_db_has() { grep -qF -- "$2" "$FAKE_DB/app/$1" || fail "DB file $1 does not contain: $2"; }
assert_db_lacks() { ! grep -qF -- "$2" "$FAKE_DB/app/$1" 2>/dev/null || fail "DB file $1 unexpectedly contains: $2"; }
assert_repo_has() { grep -qF -- "$2" "$REPO/$APP/$1" || fail "repo file $1 does not contain: $2"; }
assert_repo_lacks() { ! grep -qF -- "$2" "$REPO/$APP/$1" 2>/dev/null || fail "repo file $1 unexpectedly contains: $2"; }

# What the fake DB was asked to import (lines of $FAKE_DB/log starting with "import").
imports() { grep '^import' "$FAKE_DB/log" || true; }
assert_imports() { assert_eq "$(imports)" "$1" "imports"; }
assert_no_import() { assert_eq "$(imports)" "" "imports"; }

# The repo app dir and the DB are identical (ignoring formatting the export
# normalizes), and the DB branch records exactly that.
assert_in_sync() {
  local exp="$WORK/check"
  rm -rf "$exp"
  mkdir -p "$exp"
  printf 'apex export -applicationid 100 -exptype APEXLANG -dir %s\nexit\n' "$exp" \
    | FAKE_HOOK="" "$SQLCL" -S -name fake >/dev/null
  diff -r "$exp/demo-app" "$REPO/$APP" >/dev/null || fail "repo and DB differ:\n$(diff -r "$exp/demo-app" "$REPO/$APP")"
  git -C "$REPO" diff --quiet apex-db HEAD -- "$APP" || fail "apex-db and HEAD differ"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || fail "repo not clean:\n$(git -C "$REPO" status --short)"
}
