#!/usr/bin/env bats
# package metadata integration tests — existing behavior retained.
# Each test is independently isolated by bats-core; fixture subshells preserve
# the original EXIT-trap cleanup semantics.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Package update preserves SRCINFO on failed or incomplete generation" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PACKAGES_FILE="$tmp/packages.txt"
  export usage_package=demo usage_apply=true PATH="$tmp/bin:$PATH"
  touch "$PACKAGES_FILE" "$PACKAGES_DIR/demo/PKGBUILD" "$PACKAGES_DIR/demo/.nvchecker.toml"
  printf 'pkgbase = demo\n\tpkgver = 1\n\tpkgrel = 1\npkgname = demo\n' >"$PACKAGES_DIR/demo/.SRCINFO"
  cp "$PACKAGES_DIR/demo/.SRCINFO" "$tmp/original"
  cat >"$tmp/bin/pkgctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --printsrcinfo ]] || exit 2
case "${MAKEPKG_MODE:-ok}" in
  fail) printf 'partial metadata\n'; exit 12 ;;
  empty) exit 0 ;;
  incomplete) printf 'pkgbase = demo\n\tpkgver = 2\n'; exit 0 ;;
  ok) printf 'pkgbase = demo\n\tpkgver = 2\n\tpkgrel = 1\npkgname = demo\n' ;;
  *) exit 2 ;;
esac
MOCK
  chmod +x "$tmp/bin/"*

  for mode in fail empty incomplete; do
    if MAKEPKG_MODE="$mode" bash "$root/.mise/tasks/pkg/update" >"$tmp/log" 2>&1; then
      fail "pkg update accepted $mode metadata generation"
    fi
    cmp -s "$tmp/original" "$PACKAGES_DIR/demo/.SRCINFO" ||
      fail "pkg update overwrote valid metadata after $mode generation"
    grep -Fq 'preserving existing metadata' "$tmp/log" ||
      fail "pkg update omitted preservation diagnostic for $mode generation"
    if compgen -G "$PACKAGES_DIR/demo/.SRCINFO.tmp.*" >/dev/null; then
      fail "pkg update left partial metadata after $mode generation"
    fi
  done

  MAKEPKG_MODE=ok bash "$root/.mise/tasks/pkg/update" >"$tmp/log" 2>&1 ||
    fail "pkg update failed on success: $(cat "$tmp/log")"
  grep -q 'pkgver = 2' "$PACKAGES_DIR/demo/.SRCINFO" ||
    fail 'pkg update did not refresh valid metadata'
  grep -q '^pkgname = demo$' "$PACKAGES_DIR/demo/.SRCINFO" ||
    fail 'pkg update lost package outputs'
  if compgen -G "$PACKAGES_DIR/demo/.SRCINFO.tmp.*" >/dev/null; then
    fail 'pkg update left temporary metadata after successful generation'
  fi
  echo 'PASS metadata (failed, empty, incomplete generations preserve original; valid output replaces it)'
  )
}

@test "Strict installed version checks fail on unknown results" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/sample"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PATH="$tmp/bin:$PATH"
  unset GITHUB_TOKEN
  printf 'pkgbase = sample\n\tpkgname = sample\n' >"$tmp/packages/sample/.SRCINFO"
  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Q ]] || exit 33
printf '%s\n' 'sample 1-1'
MOCK
  for tool in nvchecker jq vercmp; do
    printf '#!/usr/bin/env bash\nexit 88\n' >"$tmp/bin/$tool"
  done
  cat >"$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
exit 124
MOCK
  chmod +x "$tmp/bin/"*
  output="$(usage_strict=false bash "$root/.mise/tasks/check-installed")" || fail 'non-strict check failed on a skip'
  [[ "$output" == *'Skipped (1)'* && "$output" == *'no nvchecker config'* ]] || fail 'missing skipped summary'
  if output="$(usage_strict=true bash "$root/.mise/tasks/check-installed")"; then
    fail 'strict check accepted a skipped package'
  fi
  [[ "$output" == *'Skipped (1)'* ]] || fail 'strict check omitted skipped package'
  printf '[sample]\nsource = "github"\n' >"$tmp/packages/sample/.nvchecker.toml"
  output="$(usage_strict=false bash "$root/.mise/tasks/check-installed")" || fail 'non-strict check failed on a warning'
  [[ "$output" == *'Warnings (1)'* ]] || fail 'upstream timeout warning was not counted'
  if usage_strict=true bash "$root/.mise/tasks/check-installed" >"$tmp/log" 2>&1; then
    fail 'strict check accepted an upstream timeout'
  fi
  echo 'PASS strict_skipped (missing config and timeout only fail in strict mode)'
  )
}

@test "SRCINFO consistency check rejects missing or stale metadata" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/sample"
  printf 'pkgname=sample\npkgver=1\npkgrel=1\n' >"$tmp/sample/PKGBUILD"
  printf 'pkgbase = sample\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = sample\n\n' >"$tmp/sample/.SRCINFO"
  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --printsrcinfo ]] || exit 2
[[ "${MOCK_MAKEPKG_FAIL:-false}" != true ]] || { printf 'partial\n'; exit 17; }
version="$(sed -n 's/^pkgver=//p' PKGBUILD)"
printf 'pkgbase = sample\n\tpkgver = %s\n\tpkgrel = 1\n\npkgname = sample\n\n' "$version"
MOCK
  chmod +x "$tmp/bin/makepkg"
  PATH="$tmp/bin:$PATH" bash "$root/tests/check-srcinfo.sh" "$tmp/sample" || fail 'consistent metadata rejected'
  sed -i 's/pkgver=1/pkgver=2/' "$tmp/sample/PKGBUILD"
  if PATH="$tmp/bin:$PATH" bash "$root/tests/check-srcinfo.sh" "$tmp/sample" >"$tmp/log" 2>&1; then
    fail 'stale metadata accepted'
  fi
  if MOCK_MAKEPKG_FAIL=true PATH="$tmp/bin:$PATH" bash "$root/tests/check-srcinfo.sh" "$tmp/sample" >"$tmp/log" 2>&1; then
    fail 'failed metadata generation accepted'
  fi
  rm -f -- "$tmp/sample/.SRCINFO"
  if PATH="$tmp/bin:$PATH" bash "$root/tests/check-srcinfo.sh" "$tmp/sample" >"$tmp/log" 2>&1; then
    fail 'missing metadata accepted'
  fi
  echo 'PASS srcinfo_consistency (matching, stale, generation failure, missing metadata)'
  )
}

@test "Metadata generation and field reads fail without leaking partial data" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/pkg"
  touch "$tmp/pkg/PKGBUILD"
  source "$root/.mise/lib/pkg/metadata.sh"

  makepkg() {
    [[ "$1" == --printsrcinfo ]] || return 2
    if [[ "${MAKEPKG_MODE:-ok}" == partial ]]; then
      printf 'pkgbase = demo\n\tpkgver = 1\n\tdepends = incomplete>=1\n'
      return 47
    fi
    printf 'pkgbase = demo\n\tpkgver = 2\n\tpkgrel = 1\n\npkgname = demo\n'
  }

  if MAKEPKG_MODE=partial pkg::cache_srcinfo "$tmp/pkg" >"$tmp/log" 2>&1; then
    fail 'partial makepkg metadata was accepted'
  fi
  [[ -z "${PKG_SRCINFO_CACHE[$tmp/pkg]+x}" ]] ||
    fail 'failed makepkg output poisoned the metadata cache'

  MAKEPKG_MODE=ok pkg::cache_srcinfo "$tmp/pkg" ||
    fail 'retry after failed metadata generation was rejected'
  [[ "$(pkg::metadata_outputs "$tmp/pkg")" == demo ]] ||
    fail 'retry did not load valid package name'
  [[ "$(pkg::metadata_version "$tmp/pkg")" == 2-1 ]] ||
    fail 'retry did not load valid package version'
  [[ -z "$(pkg::metadata_deps "$tmp/pkg")" ]] ||
    fail 'partial dependencies leaked into successful metadata cache'
  echo 'PASS metadata cache (failed generation not cached; retry succeeds)'

  # Model field readers that emit partial data and then fail. Later, valid
  # fields must not erase the failure of an earlier dependency or provider.
  pkg::metadata_values() {
    local key="$2"
    case "$key" in
      depends) printf 'runtime>=1\n' ;;
      makedepends) printf 'builder\n' ;;
      provides) printf 'virtual=1\n' ;;
      provides_x86_64) printf 'arch-virtual=1\n' ;;
      pkgname) printf 'demo\n' ;;
      pkgbase) printf 'demo\n' ;;
      pkgver) printf '2\n' ;;
      pkgrel) printf '1\n' ;;
    esac
    [[ "${FAILED_FIELD:-}" != "$key" ]] || return 48
    return 0
  }
  export CARCH=x86_64

  local field
  for field in depends makedepends provides provides_x86_64 pkgname pkgbase pkgver pkgrel; do
    case "$field" in
      depends|makedepends)
        if FAILED_FIELD="$field" pkg::metadata_deps "$tmp/pkg" >"$tmp/log"; then
          fail "dependency reader ignored failed $field field"
        fi
        ;;
      provides|provides_x86_64)
        if FAILED_FIELD="$field" pkg::metadata_provides "$tmp/pkg" >"$tmp/log"; then
          fail "provides reader ignored failed $field field"
        fi
        ;;
      pkgname)
        if FAILED_FIELD="$field" pkg::metadata_outputs "$tmp/pkg" >"$tmp/log"; then
          fail 'output reader ignored failed pkgname field'
        fi
        ;;
      pkgbase)
        if FAILED_FIELD="$field" pkg::metadata_pkgbase "$tmp/pkg" >"$tmp/log"; then
          fail 'pkgbase reader ignored failed pkgbase field'
        fi
        ;;
      pkgver|pkgrel)
        if FAILED_FIELD="$field" pkg::metadata_version "$tmp/pkg" >"$tmp/log"; then
          fail "version reader ignored failed $field field"
        fi
        ;;
    esac
  done

  [[ "$(FAILED_FIELD=none pkg::metadata_deps "$tmp/pkg")" == $'builder\nruntime>=1' ]] ||
    fail 'valid dependency aggregation changed'
  [[ "$(FAILED_FIELD=none pkg::metadata_provides "$tmp/pkg")" == $'arch-virtual=1\nvirtual=1' ]] ||
    fail 'valid provider aggregation changed'
  echo 'PASS metadata field reads (all reader failures propagate; valid aggregation preserved)'
  )
}

@test "Installed version checks treat comparator errors as warnings" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/sample"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PATH="$tmp/bin:$PATH"
  unset GITHUB_TOKEN

  printf 'pkgbase = sample\n\tpkgname = sample\n' >"$PACKAGES_DIR/sample/.SRCINFO"
  printf '[sample]\nsource = "github"\n' >"$PACKAGES_DIR/sample/.nvchecker.toml"

  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Q ]] || exit 2
printf 'sample 1.0-1\n'
MOCK
  cat >"$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --kill-after=1s && "$2" == 30s ]] || exit 2
shift 2
exec "$@"
MOCK
  cat >"$tmp/bin/nvchecker" <<'MOCK'
#!/usr/bin/env bash
printf '{"event":"updated","name":"sample","version":"2.0"}\n'
MOCK
  cat >"$tmp/bin/jq" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Rrs && "$2" == --arg ]] || exit 2
printf '2.0\n'
MOCK
  cat >"$tmp/bin/vercmp" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == 1.0 && "$2" == 2.0 ]] || exit 2
if [[ "${VERCMP_MODE:-ok}" == fail ]]; then
  printf 'partial\n'
  exit 43
fi
printf '%s\n' '-1'
MOCK
  chmod +x "$tmp/bin/"*

  VERCMP_MODE=fail usage_strict=false bash "$root/.mise/tasks/check-installed" >"$tmp/log" 2>&1 ||
    fail "non-strict check aborted after comparator failure: $(cat "$tmp/log")"
  grep -Fq 'Warnings (1):' "$tmp/log" ||
    fail 'failed version comparison was not reported as a warning'
  grep -Fq 'unsupported comparison' "$tmp/log" ||
    fail 'failed version comparison was not labeled unknown'

  if VERCMP_MODE=fail usage_strict=true bash "$root/.mise/tasks/check-installed" >"$tmp/log" 2>&1; then
    fail 'strict installed version check accepted unknown comparison'
  else
    [[ "$?" -eq 1 ]] || fail 'strict mode did not return its usual warning status'
  fi
  grep -Fq 'Warnings (1):' "$tmp/log" ||
    fail 'strict mode lost the failed comparison warning'

  VERCMP_MODE=ok usage_strict=true bash "$root/.mise/tasks/check-installed" >"$tmp/log" 2>&1 ||
    fail "valid comparator was rejected: $(cat "$tmp/log")"
  grep -Fq 'Outdated (1):' "$tmp/log" ||
    fail 'valid version comparison no longer classified outdated packages'
  )
}

@test "Outdated listing fails closed if tee fails even when pkgctl exits normally" {
  (
  local tmp mode rc
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages"
  export PACKAGES_FILE="$tmp/missing-selection" PATH="$tmp/bin:$PATH"
  touch "$PACKAGES_DIR/demo/PKGBUILD" "$PACKAGES_DIR/demo/.nvchecker.toml"

  cat >"$tmp/bin/pkgctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == version && "$2" == check ]] || exit 81
printf ' ! demo: upgrade from version 1 to 2\n' >&2
exit "${PKGCTL_STATUS:-0}"
MOCK
  cat >"$tmp/bin/tee" <<'MOCK'
#!/usr/bin/env bash
if [[ "${TEE_MODE:-pass}" == fail ]]; then
  printf 'partial output\n' >"$1"
  exit 43
fi
exec /usr/bin/tee "$@"
MOCK
  chmod +x "$tmp/bin/"*

  for mode in 0 2; do
    if PKGCTL_STATUS="$mode" TEE_MODE=fail usage_list_outdated=true usage_package=demo \
      bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err"; then
      fail "outdated list succeeded despite tee failure (pkgctl=$mode)"
    else
      rc=$?
      [[ "$rc" -eq 43 ]] || fail "tee failure status lost (pkgctl=$mode, status=$rc)"
    fi
    [[ ! -s "$tmp/out" ]] || fail "partial outdated list was printed (pkgctl=$mode)"
    grep -Fq 'tee exited 43' "$tmp/err" ||
      fail "tee failure diagnostic missing (pkgctl=$mode)"
  done

  for mode in 0 2; do
    PKGCTL_STATUS="$mode" TEE_MODE=pass usage_list_outdated=true usage_package=demo \
      bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err" ||
      fail "valid outdated listing rejected pkgctl status $mode: $(cat "$tmp/err")"
    [[ "$(cat "$tmp/out")" == demo ]] ||
      fail "outdated package lost with valid capture (pkgctl=$mode)"
  done

  if PKGCTL_STATUS=7 TEE_MODE=pass usage_list_outdated=true usage_package=demo \
    bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err"; then
    fail 'unexpected pkgctl failure was normalized to success'
  else
    [[ "$?" -eq 7 ]] || fail 'unexpected pkgctl failure exit status was lost'
  fi
  [[ ! -s "$tmp/out" ]] || fail 'pkgctl failure produced an incomplete outdated list'
  )
}

@test "Installed-version checker rejects missing package sources in strict and regular modes" {
  (
  local tmp sources mode rc
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/empty sources"
  printf 'not a directory\n' >"$tmp/not-a-directory"
  export PKGBUILDS_ROOT="$root" PATH="$tmp/bin:$PATH" TEST_TMP="$tmp"

  for tool in nvchecker jq vercmp timeout; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$tmp/bin/$tool"
  done
  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/pacman-called"
[[ "$1" == -Q ]] || exit 2
printf 'demo 1-1\n'
MOCK
  chmod +x "$tmp/bin/"*

  for sources in "$tmp/missing sources" "$tmp/not-a-directory"; do
    for mode in false true; do
      rm -f "$tmp/pacman-called"
      if PACKAGES_DIR="$sources" usage_strict="$mode" \
        bash "$root/.mise/tasks/check-installed" >"$tmp/log" 2>&1; then
        fail "check-installed accepted invalid sources (strict=$mode): $sources"
      else
        rc=$?
        [[ "$rc" -eq 1 ]] || fail "invalid source path returned $rc, not 1"
      fi
      grep -Fq 'package source directory does not exist or is inaccessible' "$tmp/log" ||
        fail "missing source directory diagnostic for: $sources"
      [[ ! -e "$tmp/pacman-called" ]] ||
        fail 'check-installed enumerated installed packages before source validation'
    done
  done

  PACKAGES_DIR="$tmp/empty sources" usage_strict=true \
    bash "$root/.mise/tasks/check-installed" >"$tmp/log" 2>&1 ||
    fail "valid empty source directory was rejected: $(cat "$tmp/log")"
  grep -Fq 'Checked 0 installed local package(s).' "$tmp/log" ||
    fail 'valid empty source directory no longer reports zero checked packages'
  )
}

@test "Git updates compare commit identities and never upgrade to raw hashes" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/current-git" "$tmp/packages/changed-git" "$tmp/packages/release"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages"
  export PACKAGES_FILE="$tmp/packages.txt" PATH="$tmp/bin:$PATH" TEST_TMP="$tmp"
  printf '%s\n' current-git changed-git release >"$PACKAGES_FILE"

  local name
  for name in current-git changed-git release; do
    printf 'pkgname=%s\npkgver=1.0.r2.gabcdef1\npkgrel=1\n' "$name" >"$PACKAGES_DIR/$name/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = 1.0.r2.gabcdef1\n\tpkgrel = 1\npkgname = %s\n' "$name" "$name" >"$PACKAGES_DIR/$name/.SRCINFO"
    if [[ "$name" == release ]]; then
      printf '[release]\nsource = "github"\n' >"$PACKAGES_DIR/$name/.nvchecker.toml"
    else
      printf '[%s]\nsource = "git"\nuse_commit = true\n' "$name" >"$PACKAGES_DIR/$name/.nvchecker.toml"
    fi
    cp "$PACKAGES_DIR/$name/PKGBUILD" "$tmp/$name.original"
    cp "$PACKAGES_DIR/$name/.SRCINFO" "$tmp/$name.srcinfo"
  done

  cat >"$tmp/bin/pkgctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == version ]] || exit 81
if [[ "$2" == upgrade ]]; then
  shift 2
  printf '%s\n' "$@" >"$TEST_TMP/upgrade"
  [[ "$#" -eq 1 && "$1" == "$PACKAGES_DIR/release" ]] || exit 82
  exit 0
fi
[[ "$2" == check && "$3" == --verbose && "$4" == --json ]] || exit 83
shift 4
python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import sys
results = []
for path in sys.argv[1:]:
    name = Path(path).name
    local = "1.0.r2.gabcdef1"
    if name == "release":
        local, upstream, outdated, status = "1.0", "2.0", True, "success"
    elif name == "current-git":
        upstream, outdated, status = "abcdef1" + "0" * 33, True, "success"
    else:
        upstream, outdated, status = "0123456" + "0" * 33, False, "warning"
    if os.environ.get("CHECK_MODE") == "failure" and name == "changed-git":
        status, upstream = "failure", None
    results.append(dict(pkgbase=name, local_version=local, upstream_version=upstream,
                        status=status, message=None, out_of_date=outdated))
if os.environ.get("CHECK_MODE") == "incomplete":
    results.pop()
print(json.dumps(results))
PY
MOCK
  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --printsrcinfo && "$(basename "$PWD")" == release ]] || exit 84
printf 'pkgbase = release\n\tpkgver = 2.0\n\tpkgrel = 1\npkgname = release\n'
MOCK
  chmod +x "$tmp/bin/"*

  usage_list_outdated=true bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err" ||
    fail "commit-aware list failed: $(cat "$tmp/err")"
  [[ "$(cat "$tmp/out")" == $'changed-git\nrelease' ]] ||
    fail 'commit-aware list included current hash or missed changed hash/release'
  usage_json=true usage_verbose=true bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err" ||
    fail "commit-aware JSON failed: $(cat "$tmp/err")"
  python3 - "$tmp/out" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    results = {row["pkgbase"]: row for row in json.load(stream)}
assert results["current-git"]["out_of_date"] is False
assert results["changed-git"]["out_of_date"] is True
assert results["release"]["out_of_date"] is True
PY

  usage_apply=true bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err" ||
    fail "mixed apply failed: $(cat "$tmp/err")"
  [[ "$(cat "$tmp/upgrade")" == "$PACKAGES_DIR/release" ]] ||
    fail 'apply passed a Git recipe to pkgctl upgrade'
  grep -Fq 'mise run pkg:build changed-git --force' "$tmp/out" ||
    fail 'apply omitted the Git rebuild instruction'
  for name in current-git changed-git; do
    cmp -s "$tmp/$name.original" "$PACKAGES_DIR/$name/PKGBUILD" ||
      fail "apply changed Git PKGBUILD: $name"
    cmp -s "$tmp/$name.srcinfo" "$PACKAGES_DIR/$name/.SRCINFO" ||
      fail "apply changed Git SRCINFO: $name"
  done
  grep -Fq 'pkgver = 2.0' "$PACKAGES_DIR/release/.SRCINFO" ||
    fail 'release metadata was not refreshed'

  rm -f "$tmp/upgrade"
  usage_apply=true usage_package=changed-git bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err" ||
    fail "Git-only apply failed: $(cat "$tmp/err")"
  [[ ! -e "$tmp/upgrade" ]] || fail 'Git-only apply invoked pkgctl upgrade'

  for mode in failure incomplete; do
    if CHECK_MODE="$mode" usage_list_outdated=true bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err"; then
      fail "outdated list accepted $mode JSON"
    fi
    [[ ! -s "$tmp/out" ]] || fail "outdated list emitted partial results after $mode"
    if CHECK_MODE="$mode" usage_apply=true bash "$root/.mise/tasks/pkg/update" >"$tmp/out" 2>"$tmp/err"; then
      fail "apply accepted $mode Git checks"
    fi
    [[ ! -e "$tmp/upgrade" ]] || fail "apply ran after $mode Git checks"
  done
  )
}
