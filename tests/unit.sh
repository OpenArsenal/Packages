#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
# Only pure shell logic is tested here; no Arch tools, DB, or package fixtures.
source "$root/.mise/lib/spec.sh"
source "$root/.mise/lib/repo/inspect.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_parse() {
  local raw="$1" expected_name="$2" expected_op="$3" expected_ver="$4"
  local name="" op="" ver=""
  spec::parse "$raw" name op ver
  [[ "$name" == "$expected_name" && "$op" == "$expected_op" && "$ver" == "$expected_ver" ]] ||
    fail "parsing '$raw': got '$name' '$op' '$ver'"
}

assert_parse 'openssl' 'openssl' '' ''
assert_parse 'nodejs>=22.12.0' 'nodejs' '>=' '22.12.0'
assert_parse 'electron-castlab=41.10.7+wvcus' 'electron-castlab' '=' '41.10.7+wvcus'
assert_parse 'gcc>13' 'gcc' '>' '13'
assert_parse 'cuda<12.4' 'cuda' '<' '12.4'
assert_parse 'glibc<=2.40' 'glibc' '<=' '2.40'
assert_parse $'  example >= 2:1.0-1\r\n' 'example' '>=' '2:1.0-1'
printf 'PASS unit dependency spec parsing\n'

# Mock the comparison result: test our decisions, not Arch's vercmp.
vercmp() {
  case "${VERCMP_MODE:-ok}" in
    fail) return 47 ;;
    malformed) printf 'unparseable\n'; return 0 ;;
  esac
  case "$1:$2" in
    0:1) printf '%s\n' '-1' ;;
    1:1) printf '%s\n' '0' ;;
    2:1) printf '%s\n' '1' ;;
    *) return 48 ;;
  esac
}

assert_version() {
  local expected="$1" actual="$2" op="$3" wanted="$4"
  if repo::version_satisfies "$actual" "$op" "$wanted"; then
    [[ "$expected" == true ]] || fail "unexpected match: $actual $op $wanted"
  else
    [[ "$expected" == false ]] || fail "unexpected rejection: $actual $op $wanted"
  fi
}

assert_version true 1 '=' 1
assert_version false 2 '=' 1
assert_version true 2 '>' 1
assert_version false 0 '>' 1
assert_version true 0 '<' 1
assert_version false 2 '<' 1
assert_version true 0 '<=' 1
assert_version true 1 '<=' 1
assert_version true 2 '>=' 1
assert_version false 0 '>=' 1
assert_version false 1 '!=' 1
VERCMP_MODE=fail assert_version false 1 '=' 1
VERCMP_MODE=fail assert_version false 1 '<=' 1
VERCMP_MODE=malformed assert_version false 1 '=' 1
VERCMP_MODE=fail assert_version true 1 '' ''
printf 'PASS unit version constraints (including failed comparisons)\n'

# Keep only the highest version; a failed comparison must not update the index.
declare -A versions=()
repo::remember_max_version versions demo 1 || fail 'could not initialize version index'
repo::remember_max_version versions demo 0 || fail 'could not compare older version'
[[ "${versions[demo]}" == 1 ]] || fail 'older version replaced indexed version'
repo::remember_max_version versions demo 2 || fail 'could not compare newer version'
[[ "${versions[demo]}" == 2 ]] || fail 'newer version not indexed'
versions[demo]=1
for mode in fail malformed; do
  if VERCMP_MODE="$mode" repo::remember_max_version versions demo 2; then
    fail "accepted $mode comparison when indexing versions"
  fi
  [[ "${versions[demo]}" == 1 ]] || fail "index changed after $mode comparison"
done
printf 'PASS unit indexed version selection (including comparator failures)\n'
