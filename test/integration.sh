#!/usr/bin/env bash
# Integration test against a real database with APEX 26.2+ and SQLcl 26.3+.
#
# Copies an existing app to a scratch application id, then runs uc-apex-sync.sh
# against the copy: local and "colleague" changes, a colleague saving between
# export and import, a new page, a deleted page. The source app is only
# exported, never changed. The scratch app is removed at the end.
#
#   IT_DB_CONN=my-conn IT_SOURCE_APP_ID=154 test/integration.sh
#
#   IT_DB_CONN        SQLcl saved connection (sql -name)                required
#   IT_SOURCE_APP_ID  app to copy; must use the Universal Theme         required
#   IT_APP_ID         scratch app id; overwritten!               (default 9154)
#   IT_KEEP=1         keep the scratch app and the temp dir for inspection

set -euo pipefail

CONN=${IT_DB_CONN:?set IT_DB_CONN}
SRC_ID=${IT_SOURCE_APP_ID:?set IT_SOURCE_APP_ID}
IT_ID=${IT_APP_ID:-9154}
ALIAS=UC-APEX-SYNC-IT
DIR_NAME=uc-apex-sync-it
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/uc-apex-sync.sh"
REAL_SQL=$(command -v "${SQLCL:-sql}")

[ "$IT_ID" != "$SRC_ID" ] || { echo "IT_APP_ID must differ from IT_SOURCE_APP_ID" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/uc-apex-sync-it.XXXXXX")
REPO=$WORK/repo
APP=src/app/$DIR_NAME
STEP=""
OWNED=0 # set once we know IT_APP_ID is ours to overwrite and remove

sqlq() { printf 'set heading off feedback off pagesize 0\n%s\nexit\n' "$1" | "$REAL_SQL" -S -name "$CONN" 2>&1; }
apx() { printf '%s\nexit\n' "$1" | "$REAL_SQL" -S -name "$CONN" 2>&1; }

cleanup() {
  local rc=$?
  if [ "${IT_KEEP:-0}" = 1 ]; then
    echo "kept app $IT_ID and $WORK"
  elif [ $OWNED = 1 ]; then
    sqlq "declare l_ws varchar2(255);
begin
  select workspace into l_ws from apex_applications where application_id = $IT_ID;
  apex_application_install.set_workspace(l_ws);
  apex_application_install.remove_application($IT_ID);
  commit;
end;
/" >/dev/null || true
  fi
  [ "${IT_KEEP:-0}" = 1 ] || rm -rf "$WORK"
  [ $rc -eq 0 ] || echo "FAILED in step: $STEP" >&2
}
trap cleanup EXIT

step() { STEP=$1; echo "--- $1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
run() {
  RC=0
  OUT=$("$SCRIPT" "$@" 2>&1 </dev/null) || RC=$?
  sed 's/^/    | /' <<<"$OUT"
}
assert_ok() { [ "$RC" -eq 0 ] || fail "expected success, got rc=$RC"; }
assert_out() { grep -qF -- "$1" <<<"$OUT" || fail "output lacks: $1"; }

# Export the scratch app and compare it with the repo.
db_export() {
  rm -rf "$WORK/check"
  apx "apex export -applicationid $IT_ID -exptype APEXLANG -dir $WORK/check -overwrite-files" >/dev/null
}
assert_db_has() { db_export; grep -qF -- "$2" "$WORK/check/$DIR_NAME/$1" || fail "DB $1 lacks: $2"; }
assert_in_sync() {
  db_export
  diff -r -x apex-exports "$WORK/check/$DIR_NAME" "$REPO/$APP" || fail "repo and DB differ"
  git -C "$REPO" diff --quiet apex-db HEAD -- "$APP" || fail "apex-db and HEAD differ"
}

# A colleague changes a page: edit a copy of the app and import just that file.
colleague_edit() { # <file> <sed expr>
  rm -rf "$WORK/colleague"
  cp -R "$REPO/$APP" "$WORK/colleague"
  sed -i.bak "$2" "$WORK/colleague/$1" && rm -f "$WORK/colleague/$1.bak"
  local out
  out=$(apx "apex import -input $WORK/colleague -files $WORK/colleague/$1")
  grep -q 'Import successful' <<<"$out" || fail "colleague import failed:\n$out"
}

export SQLCL=$REAL_SQL DB_CONN=$CONN APP_ID=$IT_ID APP_DIR=$APP
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

step "copy app $SRC_ID to scratch app $IT_ID"
existing=$(sqlq "select alias from apex_applications where application_id = $IT_ID;" | tr -d '[:space:]')
[ -z "$existing" ] || [ "$existing" = "$ALIAS" ] \
  || fail "app $IT_ID exists and is not a scratch app ($existing); choose another IT_APP_ID"
OWNED=1
apx "apex export -applicationid $SRC_ID -exptype APEXLANG -dir $WORK/source -overwrite-files" >/dev/null
src=$(find "$WORK/source" -mindepth 1 -maxdepth 1 -type d | head -n 1)
out=$(apx "apex import -input $src -id $IT_ID -alias $ALIAS")
grep -q 'Import successful' <<<"$out" || fail "import of the copy failed:\n$out"

step "repo with the exported scratch app, init"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
apx "apex export -applicationid $IT_ID -exptype APEXLANG -dir src/app -overwrite-files" >/dev/null
[ -f "$APP/application.apx" ] || fail "export of $IT_ID did not land in $APP"
git add -A && git commit -q -m "initial export"
run init
assert_ok

list_pages() { find "$APP/pages" -name 'p*.apx' ! -name 'p00000-*' | sort | sed "s|^$APP/||"; }
PAGES=$(list_pages)
PA=$(sed -n 2p <<<"$PAGES")
PB=$(sed -n 3p <<<"$PAGES")
PC=$(sed -n 4p <<<"$PAGES")
echo "    pages used: $PA $PB $PC"

step "local change + colleague change in another page -> partial import"
colleague_edit "$PB" 's/^    title: \(.*\)$/    title: \1 (colleague)/'
sed -i.bak 's/^    title: \(.*\)$/    title: \1 (local)/' "$APP/$PA" && rm -f "$APP/$PA.bak"
run sync -y -m "local title change"
assert_ok
assert_out "DB has changes since the last sync"
assert_out "import: only these files"
assert_db_has "$PA" "(local)"
assert_db_has "$PB" "(colleague)"
assert_in_sync

step "colleague saves between export and import -> abort, then succeed"
sed -i.bak 's/^    title: \(.*\)$/    title: \1 (race)/' "$APP/$PC" && rm -f "$APP/$PC.bak"
git commit -qam "race test"
# A wrapper around SQLcl that lets the colleague import before session 2
# (the checksum check right before the import).
cat >"$WORK/sql-race" <<EOF
#!/usr/bin/env bash
case " \$* " in *" -nolog "*) exec "$REAL_SQL" "\$@" ;; esac
n=\$(( \$(cat "$WORK/race-calls" 2>/dev/null || echo 0) + 1 ))
echo \$n >"$WORK/race-calls"
if [ \$n = 2 ]; then
  rm -rf "$WORK/colleague"; cp -R "$REPO/$APP" "$WORK/colleague"
  git -C "$REPO" show "HEAD~1:$APP/$PC" >"$WORK/colleague/$PC"
  sed -i.bak 's/^    name: \(.*\)$/    name: \1 (meanwhile)/' "$WORK/colleague/$PC"
  printf 'apex import -input %s -files %s\nexit\n' "$WORK/colleague" "$WORK/colleague/$PC" | "$REAL_SQL" -S -name "$CONN" >/dev/null 2>&1
fi
exec "$REAL_SQL" "\$@"
EOF
chmod +x "$WORK/sql-race"
SQLCL=$WORK/sql-race run sync -y
[ "$RC" -ne 0 ] || fail "sync should have aborted"
assert_out "was changed in the DB since the export"
run sync -y
assert_ok
assert_db_has "$PC" "(race)"
assert_db_has "$PC" "(meanwhile)"
assert_in_sync

step "new page -> partial import"
cat >"$APP/pages/p09901-uc-apex-sync-it.apx" <<'EOF'
page 9901 (
    name: uc-apex-sync IT
    alias: UC-APEX-SYNC-IT
    title: uc-apex-sync IT
    appearance {
        pageTemplate: @/standard
    }

    region hello (
        name: Hello
        type: staticContent
        layout {
            sequence: 10
            slot: body
        }
        source {
            htmlCode: Added by a partial import
        }
    )
)
EOF
run sync -y -m "new page"
assert_ok
assert_out "pages/p09901-uc-apex-sync-it.apx"
assert_db_has pages/p09901-uc-apex-sync-it.apx "Added by a partial import"
assert_in_sync

step "deleted page -> full import"
git rm -q "$APP/pages/p09901-uc-apex-sync-it.apx"
git commit -qm "remove page"
run sync -y
assert_ok
assert_out "import: full app"
db_export
[ ! -f "$WORK/check/$DIR_NAME/pages/p09901-uc-apex-sync-it.apx" ] || fail "page 9901 still in DB"
assert_in_sync

step "nothing left to do"
run sync -y
assert_ok
assert_out "nothing to import"

STEP=""
echo "integration test passed"
