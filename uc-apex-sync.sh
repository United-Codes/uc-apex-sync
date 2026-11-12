#!/usr/bin/env bash
# uc-apex-sync: merge-safe APEXlang imports for Oracle APEX apps in Git.
#
# Before importing your local APEXlang files, export the app from the database,
# three-way merge what others changed in the App Builder with what you changed
# locally, and only then import. On APEX 26.2+ only the changed components are
# imported, so everything else in the app is left untouched.
#
# The trick is a second branch (DB_BRANCH, default `apex-db`) that only ever
# holds what the database looked like at the last sync. It is the common base
# Git needs for a real three-way merge.
#
# Usage: uc-apex-sync <command> [options]
#
#   init [<commit>]        Create DB_BRANCH. Without <commit>, export the app and
#                          use the newest commit whose app dir matches the DB.
#   pull [-m <msg>]        Export the DB and merge its changes into SYNC_BRANCH.
#                          Never writes to the database.
#   sync [options] [<path>...]
#                          pull, validate, then import into the database.
#        -y, --yes         Do not ask before importing.
#        -m, --message     Commit message for uncommitted app changes.
#        --full            Import the whole app instead of the changed files.
#        <path>...         Import only changes under these paths (relative to
#                          APP_DIR, globs allowed). Requires APEX 26.2+.
#   status [<path>...]     Show what sync would import. Offline.
#
# Configuration (environment variables; the example makefile passes them):
#   DB_CONN        SQLcl saved connection name (sql -name)           required
#   APP_ID         application id                                    required
#   APP_DIR        app directory in the repo, e.g. src/app/my-app    required
#                  The export writes to its parent dir, using the app
#                  alias as folder name, so the folder must match the alias.
#   SYNC_BRANCH    branch you work on and import from      (default: main)
#   DB_BRANCH      branch mirroring the DB, one per app/DB  (default: apex-db)
#   APEX_WORKSPACE workspace name, if the connection can see several
#   SQLCL          SQLcl executable                         (default: sql)
#   MSG            same as -m
#
# Install once and upgrade with git pull:
#   git clone https://github.com/United-Codes/uc-apex-sync && make -C uc-apex-sync install
#
# https://github.com/United-Codes/uc-apex-sync  (MIT License)

set -euo pipefail

VERSION=1.0.0

die() { printf 'uc-apex-sync: %b\n' "$*" >&2; exit 1; }
log() { printf '==> %b\n' "$*"; }
warn() { printf 'uc-apex-sync: warning: %b\n' "$*" >&2; }

indent() { sed 's/^/    /'; }

usage() { sed -n '/^# Usage:/,/^# https/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'; }

# --- configuration ----------------------------------------------------------

load_config() {
  DB_CONN=${DB_CONN:-}
  APP_ID=${APP_ID:-}
  APP_DIR=${APP_DIR:-}
  [ -n "$APP_DIR" ] || die "APP_DIR not set (e.g. APP_DIR=src/app/my-app)"
  APP_DIR=${APP_DIR#./}
  APP_DIR=${APP_DIR%/}
  EXPORT_DIR=$(dirname "$APP_DIR")
  BRANCH=${DB_BRANCH:-apex-db}
  MAIN=${SYNC_BRANCH:-main}
  SQLCL=${SQLCL:-sql}
  WS_OPT=""
  [ -z "${APEX_WORKSPACE:-}" ] || WS_OPT=" -workspace ${APEX_WORKSPACE}"

  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a Git repository"
  cd "$ROOT"
  WT="$(cd "$(git rev-parse --git-common-dir)" && pwd)/${BRANCH//\//-}-worktree"
}

need_db() {
  [ -n "$DB_CONN" ] || die "DB_CONN not set (name of a SQLcl saved connection)"
  [ -n "$APP_ID" ] || die "APP_ID not set"
  case $APP_ID in *[!0-9]*) die "APP_ID must be a number, got '$APP_ID'" ;; esac
}

# --- SQLcl ------------------------------------------------------------------

# Run SQLcl commands against DB_CONN. SQLcl exits 0 even when an apex command
# fails, so callers inspect the output.
run_sql() {
  printf '%s\nexit\n' "$1" | "$SQLCL" -S -name "$DB_CONN" 2>&1
}

run_sql_nolog() {
  printf '%s\nexit\n' "$1" | "$SQLCL" -S -nolog 2>&1
}

checksum_cmd() {
  printf 'apex export -applicationid %s -exptype CHECKSUM-SH256 -dir %s -overwrite-files' "$APP_ID" "$1"
}

read_checksum() {
  local f
  for f in "$1"/*.sql; do
    [ -f "$f" ] && { tr -d '[:space:]' <"$f"; return 0; }
  done
  return 1
}

# Checksum of the app as it is in the DB right now. Independent of IDs and
# timestamps, so it changes with every save in the Builder and every import.
db_checksum() {
  local dir out sum
  dir=$(mktemp -d "${TMPDIR:-/tmp}/uc-apex-sync.XXXXXX")
  out=$(run_sql "$(checksum_cmd "$dir")") || true
  sum=$(read_checksum "$dir") || { rm -rf "$dir"; die "could not read checksum of app $APP_ID:\n$out"; }
  rm -rf "$dir"
  echo "$sum"
}

# Export the app into the worktree, replacing the old export so components
# deleted in the Builder disappear too. In the same SQLcl session, read the
# APEX version and the app checksum (sets APEX_VERSION and DB_SUM).
export_to_worktree() {
  local dir out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/uc-apex-sync.XXXXXX")
  if [ -d "$WT/$APP_DIR" ]; then
    # apex-exports/ holds SQL backups made by the VS Code extension; keep it.
    find "$WT/$APP_DIR" -mindepth 1 -maxdepth 1 ! -name apex-exports -exec rm -rf {} +
  fi
  mkdir -p "$WT/$EXPORT_DIR"
  out=$(run_sql "set heading off feedback off pagesize 0
select 'APEX_VERSION=' || version_no from apex_release;
$(checksum_cmd "$dir")
apex export -applicationid $APP_ID -exptype APEXLANG -dir $WT/$EXPORT_DIR -overwrite-files") || true
  APEX_VERSION=$(sed -n 's/^APEX_VERSION=\([0-9.]*\).*/\1/p' <<<"$out" | head -n 1)
  DB_SUM=$(read_checksum "$dir") || DB_SUM=""
  rm -rf "$dir"
  if grep -qE 'ORA-[0-9]+|SP2-[0-9]+' <<<"$out" || [ -z "$DB_SUM" ]; then
    die "export of app $APP_ID from $DB_CONN failed:\n$out"
  fi
  [ -f "$WT/$APP_DIR/application.apx" ] \
    || die "export did not produce $APP_DIR. Does the folder name match the app alias in lower case?\n$out"
}

# 0 = imported, 2 = APEX refused the partial file set (nothing imported),
# 1 = other error (the DB may be partially updated)
classify_import() {
  if grep -qE 'APEXLangIllegalFileImportSet|non-existent files' <<<"$1"; then
    return 2
  fi
  if grep -q 'Import successful' <<<"$1" \
    && ! grep -qE 'Import Errors|Compile Errors|ORA-[0-9]+' <<<"$1"; then
    return 0
  fi
  return 1
}

# version_ge 26.2.1 26.2 -> true
version_ge() {
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 0
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 1
  done
  return 0
}

# --- Git --------------------------------------------------------------------

branch_exists() { git rev-parse -q --verify "refs/heads/$1" >/dev/null; }

commit_worktree() {
  git -C "$WT" add -A -- "$APP_DIR"
  if git -C "$WT" diff --cached --quiet; then
    return 1
  fi
  git -C "$WT" commit -q --no-verify -m "$1"
}

ensure_worktree() {
  branch_exists "$BRANCH" \
    || die "branch $BRANCH missing; run 'uc-apex-sync init' first (make sync-init)"
  if [ ! -d "$WT" ]; then
    git worktree prune
    git worktree add -q "$WT" "$BRANCH"
  fi
  [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "$WT is not on $BRANCH"
  # The worktree only ever holds script-made exports; leftovers come from an
  # aborted run, so throw them away.
  if [ -n "$(git -C "$WT" status --porcelain)" ]; then
    warn "discarding leftovers of an aborted run in $WT"
    git -C "$WT" reset -q --hard
    git -C "$WT" clean -qfd
  fi
}

# Commit uncommitted changes in APP_DIR. They are "our" side of the merge.
# Other files, staged or not, are left alone.
commit_local_changes() {
  [ -n "$(git status --porcelain -- "$APP_DIR")" ] || return 0
  local msg=${MSG:-}
  if [ -z "$msg" ] && [ -t 0 ]; then
    log "uncommitted changes in $APP_DIR:"
    git status --short -- "$APP_DIR"
    read -r -p "Commit message: " msg
  fi
  git add -A -- "$APP_DIR"
  git commit -q -m "${msg:-App changes before DB sync}" -- "$APP_DIR"
  log "committed local changes in $APP_DIR"
}

check_preconditions() {
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$MAIN" ] \
    || die "check out $MAIN first (or set SYNC_BRANCH to the branch you import from)"
  [ "$MAIN" != "$BRANCH" ] || die "SYNC_BRANCH and DB_BRANCH must differ"
  [ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] \
    || die "a merge is in progress; resolve and commit it, then run again"
  # git merge refuses to run when anything is staged, even in unrelated files.
  git diff --cached --quiet -- . ":(exclude)$APP_DIR" \
    || die "files outside $APP_DIR are staged; commit or unstage them (git restore --staged <file>)"
}

# Export the DB into DB_BRANCH and merge it into SYNC_BRANCH.
pull_db() {
  log "exporting app $APP_ID from $DB_CONN"
  export_to_worktree
  if commit_worktree "DB snapshot of app $APP_ID from $DB_CONN"; then
    log "DB has changes since the last sync:"
    git --no-pager diff --stat "$BRANCH~1" "$BRANCH" -- "$APP_DIR"
  else
    log "DB unchanged since the last sync"
  fi

  if ! git merge -q --no-edit -m "Merge DB changes of app $APP_ID" "$BRANCH"; then
    echo
    git --no-pager diff --name-only --diff-filter=U
    die "merge conflicts above. Resolve them, commit, then run again"
  fi
}

# --- import plan ------------------------------------------------------------

# The .apx file a non-.apx file belongs to, e.g.
#   shared-components/static-files/icons/a.png -> shared-components/static-files.apx
#   supporting-objects/deinstall-script.sql   -> supporting-objects/supporting-objects.apx
owner_apx() {
  local dir sub f
  dir=$(dirname "$1")
  sub=$(basename "$1")
  while [ "$dir" != "." ]; do
    if [ -f "$APP_DIR/$dir.apx" ]; then
      echo "$dir.apx"
      return 0
    fi
    for f in "$APP_DIR/$dir"/*.apx; do
      if [ -f "$f" ] && grep -qF -- "$sub" "$f"; then
        echo "${f#"$APP_DIR"/}"
        return 0
      fi
    done
    sub="$(basename "$dir")/$sub"
    dir=$(dirname "$dir")
  done
  return 1
}

# Work out what an import of HEAD on top of DB_BRANCH needs. Sets
#   PLAN_CHANGED  changed paths (relative to APP_DIR), one per line
#   PLAN_FILES    .apx files for a partial import, one per line
#   PLAN_FULL     reason why only a full import works, or empty
plan_import() {
  local status path rel owner specs=()
  PLAN_CHANGED=""
  PLAN_FILES=""
  PLAN_FULL=""
  if [ $# -gt 0 ]; then
    for path in "$@"; do specs+=("$APP_DIR/${path#./}"); done
  else
    specs=("$APP_DIR")
  fi

  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    rel=${path#"$APP_DIR"/}
    case $rel in
      apex-exports/* | .apex/*) continue ;;
    esac
    PLAN_CHANGED+="$rel"$'\n'
    [ -z "$PLAN_FULL" ] || continue
    case $rel in
      *[[:space:]]*) PLAN_FULL="$rel contains whitespace, which -files does not support" ;;
      *.apx)
        if [ "$status" = D ]; then
          PLAN_FULL="$rel was deleted, and partial imports cannot delete components"
        else
          PLAN_FILES+="$rel"$'\n'
        fi
        ;;
      *)
        if owner=$(owner_apx "$rel"); then
          PLAN_FILES+="$owner"$'\n'
        else
          PLAN_FULL="$rel does not belong to an .apx component file"
        fi
        ;;
    esac
  done < <(git diff --name-status --no-renames "$BRANCH" HEAD -- "${specs[@]}")

  PLAN_FILES=$(printf '%s' "$PLAN_FILES" | sort -u)
  PLAN_CHANGED=${PLAN_CHANGED%$'\n'}
}

# Changed paths outside the given pathspecs (shown when importing a subset).
not_selected() {
  [ $# -gt 0 ] || return 0
  local all selected
  all=$(git diff --name-only --no-renames "$BRANCH" HEAD -- "$APP_DIR" \
    ":(exclude)$APP_DIR/apex-exports" ":(exclude)$APP_DIR/.apex" | sed "s|^$APP_DIR/||")
  selected=$PLAN_CHANGED
  comm -23 <(sort <<<"$all") <(sort <<<"$selected") | sed '/^$/d'
}

# --- commands ---------------------------------------------------------------

cmd_init() {
  local base=${1:-}
  branch_exists "$BRANCH" && die "branch $BRANCH already exists"
  if [ -n "$base" ]; then
    git rev-parse -q --verify "$base^{commit}" >/dev/null || die "unknown commit: $base"
    git branch "$BRANCH" "$base"
    log "created $BRANCH at $(git rev-parse --short "$base")"
    return 0
  fi

  need_db
  # Export into a throwaway worktree and look for a commit with the same tree.
  local tmp_wt=$WT
  WT=$(mktemp -d "${TMPDIR:-/tmp}/uc-apex-sync-init.XXXXXX")
  rmdir "$WT"
  git worktree add -q --detach "$WT" HEAD
  # shellcheck disable=SC2064
  trap "git worktree remove --force '$WT' >/dev/null 2>&1 || true" EXIT
  log "exporting app $APP_ID from $DB_CONN"
  export_to_worktree
  git -C "$WT" add -A -- "$APP_DIR"
  local tree c match=""
  tree=$(git -C "$WT" write-tree --prefix="$APP_DIR/" 2>/dev/null) || die "empty export"
  for c in $(git rev-list HEAD -- "$APP_DIR"); do
    if [ "$(git rev-parse -q --verify "$c:$APP_DIR" 2>/dev/null)" = "$tree" ]; then
      match=$c
      break
    fi
  done
  WT=$tmp_wt
  [ -n "$match" ] || die "no commit on $(git rev-parse --abbrev-ref HEAD) matches the app in the DB.
Pass the commit of your last export explicitly: uc-apex-sync init <commit>
(or export the app, commit it, and run init again)."
  git branch "$BRANCH" "$match"
  log "created $BRANCH at $(git log -1 --format='%h %s' "$match")"
}

cmd_pull() {
  while [ $# -gt 0 ]; do
    case $1 in
      -m | --message) MSG=${2:?-m needs a message}; shift 2 ;;
      *) die "pull: unknown option $1" ;;
    esac
  done
  need_db
  check_preconditions
  ensure_worktree
  commit_local_changes
  pull_db
  log "done; $MAIN contains all DB changes"
}

cmd_status() {
  branch_exists "$BRANCH" || die "branch $BRANCH missing; run 'uc-apex-sync init' first"
  if [ -n "$(git status --porcelain -- "$APP_DIR")" ]; then
    log "uncommitted changes in $APP_DIR (sync commits them first):"
    git status --short -- "$APP_DIR"
  fi
  plan_import "$@"
  if [ -z "$PLAN_CHANGED" ]; then
    log "no committed changes to import; $MAIN matches the DB as of the last sync"
    return 0
  fi
  log "changed since the last sync (as of $BRANCH):"
  indent <<<"$PLAN_CHANGED"
  print_plan "$@"
}

print_plan() {
  if [ -n "$PLAN_FULL" ]; then
    log "import: full app ($PLAN_FULL)"
  else
    log "import: only these files (APEX 26.2+):"
    indent <<<"$PLAN_FILES"
  fi
  local rest
  rest=$(not_selected "$@")
  if [ -n "$rest" ]; then
    log "not selected, stay local until a later sync:"
    indent <<<"$rest"
  fi
}

confirm() {
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || die "$1 needs confirmation; run with -y (YES=1) to skip the prompt"
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

import_app() {
  local files=$1 out cmd rc=0
  cmd="apex import -input $APP_DIR$WS_OPT"
  if [ -n "$files" ]; then
    cmd+=" -files $(sed "s|^|$APP_DIR/|" <<<"$files" | tr '\n' ' ')"
  fi
  out=$(run_sql "$cmd") || true
  classify_import "$out" || rc=$?
  IMPORT_OUT=$out
  return $rc
}

cmd_sync() {
  local full=0 paths=()
  YES=0
  while [ $# -gt 0 ]; do
    case $1 in
      -y | --yes) YES=1; shift ;;
      -m | --message) MSG=${2:?-m needs a message}; shift 2 ;;
      --full) full=1; shift ;;
      --) shift; paths+=("$@"); break ;;
      -*) die "sync: unknown option $1" ;;
      *) paths+=("$1"); shift ;;
    esac
  done
  [ $full -eq 0 ] || [ ${#paths[@]} -eq 0 ] || die "--full cannot be combined with paths"

  need_db
  check_preconditions
  ensure_worktree
  commit_local_changes

  # --- 1. export the DB and merge their changes into ours -----------------
  pull_db
  local sum=$DB_SUM

  # --- 2. what is there to import? -----------------------------------------
  plan_import ${paths[@]+"${paths[@]}"}
  if [ -z "$PLAN_CHANGED" ]; then
    if [ ${#paths[@]} -gt 0 ] && ! git diff --quiet "$BRANCH" HEAD -- "$APP_DIR"; then
      log "nothing to import under: ${paths[*]}"
    else
      log "nothing to import; $MAIN and the DB are identical"
    fi
    return 0
  fi
  if [ $full -eq 1 ]; then
    PLAN_FULL="--full"
  elif [ -z "$PLAN_FULL" ] && ! version_ge "${APEX_VERSION:-0}" 26.2; then
    PLAN_FULL="APEX ${APEX_VERSION:-?} has no partial import (needs 26.2+)"
  fi
  if [ ${#paths[@]} -gt 0 ] && [ -n "$PLAN_FULL" ]; then
    die "cannot import only ${paths[*]}: $PLAN_FULL"
  fi

  # --- 3. validate the merged result ---------------------------------------
  log "validating $APP_DIR"
  local out
  out=$(run_sql_nolog "apex validate -input $APP_DIR") || true
  if grep -qE 'Compile Errors|Error:' <<<"$out"; then
    echo "$out" >&2
    die "validation failed; fix, commit, then run again"
  fi

  # --- 4. import, unless someone saved in the Builder meanwhile ------------
  log "changes to import into $DB_CONN:"
  local specs=("$APP_DIR") p
  if [ ${#paths[@]} -gt 0 ]; then
    specs=()
    for p in "${paths[@]}"; do specs+=("$APP_DIR/${p#./}"); done
  fi
  git --no-pager diff --stat "$BRANCH" HEAD -- "${specs[@]}"
  print_plan ${paths[@]+"${paths[@]}"}
  confirm "Import into $DB_CONN?" || die "aborted; nothing imported"

  [ "$(db_checksum)" = "$sum" ] \
    || die "app $APP_ID was changed in the DB since the export; run again to merge that change too"

  local files=""
  [ -n "$PLAN_FULL" ] || files=$PLAN_FILES
  if [ -n "$files" ]; then
    log "importing $(wc -l <<<"$files" | tr -d ' ') file(s)"
  else
    log "importing the full app"
  fi
  local rc=0
  import_app "$files" || rc=$?
  if [ $rc -eq 2 ]; then
    echo "$IMPORT_OUT" | grep -E 'Error|non-existent' >&2 || true
    [ ${#paths[@]} -eq 0 ] || die "APEX cannot import ${paths[*]} on their own; nothing imported"
    warn "APEX cannot import these files on their own; nothing was imported"
    confirm "Import the full app instead?" || die "aborted; nothing imported"
    rc=0
    import_app "" || rc=$?
  fi
  if [ $rc -ne 0 ]; then
    echo "$IMPORT_OUT" >&2
    die "import reported errors; the DB may be partially updated. Check it, then run again"
  fi

  # --- 5. record the DB as it is now as the new base -----------------------
  # Export again instead of assuming the DB equals HEAD: APEX normalizes the
  # formatting, and with a partial import only some files went in.
  log "recording the new DB state in $BRANCH"
  export_to_worktree
  commit_worktree "DB snapshot of app $APP_ID after import of $MAIN $(git rev-parse --short HEAD)" || true
  # DB_BRANCH now holds what was just imported, so where Git sees a conflict
  # (only formatting, normally) the DB version is the truth.
  git merge -q --no-edit -X theirs -m "Record import of app $APP_ID into $DB_CONN" "$BRANCH" \
    || die "could not merge $BRANCH into $MAIN after the import; resolve and commit"
  log "done; $BRANCH matches the DB"
}

main() {
  local cmd=${1:-}
  [ $# -eq 0 ] || shift
  case $cmd in
    init | pull | sync | status) load_config; "cmd_$cmd" "$@" ;;
    -h | --help | help) usage ;;
    -V | --version | version) echo "uc-apex-sync $VERSION" ;;
    "") usage >&2; exit 1 ;;
    *) die "unknown command '$cmd'; see uc-apex-sync --help" ;;
  esac
}

main "$@"
