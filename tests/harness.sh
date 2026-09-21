# Minimal test harness. A test file sources this, defines test_* functions and
# ends with `run_tests`. Each test runs in its own subshell, in a fresh
# temporary directory ($T), with `set -e` on, so an unexpected failure aborts
# just that test. Assertions record the problem and let the test continue.
#
#   run CMD...      -> $out (stdout+stderr), $rc (exit code); never aborts
#   assert_eq       ACTUAL EXPECTED [what]
#   assert_rc       ACTUAL EXPECTED [what]
#   assert_contains TEXT NEEDLE   /  assert_not_contains
#   assert_match    TEXT REGEX
#   assert_file PATH / assert_no_file PATH
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STUBS="$REPO/tests/stubs"
FIXTURES="$REPO/tests/fixtures"
_failed=

fail() { printf '      %s\n' "$@" >&2; _failed=1; }
# Long haystacks (a whole Dockerfile) are cut down; the head is what matters.
clip() { if [ "${#1}" -gt 600 ]; then printf '%s\n      ... (%d more chars)' "${1:0:600}" "$(( ${#1} - 600 ))"; else printf '%s' "$1"; fi; }
assert_eq()           { [ "$1" = "$2" ] || fail "expected${3:+ ($3)}: $2" "actual:   $1"; }
assert_rc()           { [ "$1" -eq "$2" ] || fail "exit code $1, expected $2${3:+ ($3)}"; }
assert_contains()     { case "$1" in *"$2"*) ;; *) fail "expected to contain: $2" "in: $(clip "$1")" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected NOT to contain: $2" "in: $(clip "$1")" ;; esac; }
assert_match()        { printf '%s\n' "$1" | grep -Eq -- "$2" || fail "expected to match: /$2/" "in: $(clip "$1")"; }
assert_file()         { [ -e "$1" ] || fail "expected file to exist: $1"; }
assert_no_file()      { [ ! -e "$1" ] || fail "expected no file: $1"; }

run() { rc=0; out="$("$@" 2>&1)" || rc=$?; }

# A throwaway git repository in $T, so the launcher's git-root logic engages.
mkrepo() { git init -q "$1" && (cd "$1" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init); }

run_tests() {
  local t pass=0 failn=0 T
  for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    T="$(mktemp -d "${TMPDIR:-/tmp}/cbde-test.XXXXXX")"
    printf '  %-64s' "$t"
    if ( set -e
         trap 'fail "aborted: command failed at ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}"' ERR
         export T STUB_LOG="$T/stub.log"
         cd "$T"
         "$t"
         [ -z "$_failed" ] ) 2>"$T.err"; then
      pass=$((pass + 1)); printf 'ok\n'
    else
      failn=$((failn + 1)); printf '\033[31mFAIL\033[0m\n'; cat "$T.err" >&2
    fi
    rm -rf "$T" "$T.err"
  done
  printf '  %d passed, %d failed\n' "$pass" "$failn"
  [ "$failn" = 0 ]
}
