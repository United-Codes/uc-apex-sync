#!/usr/bin/env bash
# Run the test suite against the fake SQLcl. No database needed.
#
#   test/run.sh              all tests
#   test/run.sh conflict     only tests whose name contains "conflict"

set -uo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=test/lib.sh
. ./lib.sh
# shellcheck source=test/sync.test.sh
. ./sync.test.sh

filter=${1:-}
passed=0
failed=()

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  case $t in *"$filter"*) ;; *) continue ;; esac
  if (trap teardown EXIT; setup && "$t") >"${TMPDIR:-/tmp}/uc-apex-sync-test.out" 2>&1; then
    printf '  ok    %s\n' "$t"
    passed=$((passed + 1))
  else
    printf '  FAIL  %s\n' "$t"
    sed 's/^/        /' "${TMPDIR:-/tmp}/uc-apex-sync-test.out"
    failed+=("$t")
  fi
done
rm -f "${TMPDIR:-/tmp}/uc-apex-sync-test.out"

echo
echo "$passed passed, ${#failed[@]} failed"
[ ${#failed[@]} -eq 0 ]
