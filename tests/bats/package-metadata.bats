#!/usr/bin/env bats
# package metadata integration tests — existing behavior retained.
# Each test is independently isolated by bats-core; fixture subshells preserve
# the original EXIT-trap cleanup semantics.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Package update preserves valid SRCINFO on generation failure" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PACKAGES_FILE="$tmp/packages.txt"
  export usage_package=demo usage_apply=true PATH="$tmp/bin:$PATH"
  touch "$PACKAGES_FILE" "$PACKAGES_DIR/demo/PKGBUILD" "$PACKAGES_DIR/demo/.nvchecker.toml"
  printf 'pkgbase = demo\n\tpkgver = 1\n' >"$PACKAGES_DIR/demo/.SRCINFO"
  cp "$PACKAGES_DIR/demo/.SRCINFO" "$tmp/original"
  cat >"$tmp/bin/pkgctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --printsrcinfo ]] || exit 2
if [[ "$MAKEPKG_MODE" == fail ]]; then
  printf 'partial metadata\n'
  exit 12
fi
printf 'pkgbase = demo\n\tpkgver = 2\n'
MOCK
  chmod +x "$tmp/bin/"*

  if MAKEPKG_MODE=fail bash "$root/.mise/tasks/pkg/update" >"$tmp/log" 2>&1; then
    fail 'pkg update succeeded after failed metadata generation'
  fi
  cmp -s "$tmp/original" "$PACKAGES_DIR/demo/.SRCINFO" || fail 'pkg update overwrote valid metadata'
  [[ ! -e "$PACKAGES_DIR/demo/.SRCINFO.tmp" ]] || fail 'pkg update left partial metadata'

  MAKEPKG_MODE=ok bash "$root/.mise/tasks/pkg/update" >"$tmp/log" 2>&1 || fail "pkg update failed on success: $(cat "$tmp/log")"
  grep -q 'pkgver = 2' "$PACKAGES_DIR/demo/.SRCINFO" || fail 'pkg update did not refresh valid metadata'
  [[ ! -e "$PACKAGES_DIR/demo/.SRCINFO.tmp" ]] || fail 'pkg update left temporary metadata'
  echo 'PASS metadata (failed generation preserves original, successful generation replaces it)'
  )
}

@test "Electron package aliases match their declared versions" {
  (
  local major dir actual metadata
  for major in 40 41; do
    (
      dir="$root/packages/electron${major}-castlab-bin"
      source "$dir/PKGBUILD"
      actual="$(printf '%s\n' "${provides[@]}" | LC_ALL=C sort)"
      metadata="$(sed -n 's/^[[:space:]]*provides = //p' "$dir/.SRCINFO" | LC_ALL=C sort)"
      [[ "$(sed -n 's/^[[:space:]]*pkgrel = //p' "$dir/.SRCINFO")" == "$pkgrel" ]] || fail "electron $major metadata pkgrel mismatch"
      [[ "$(sed -n 's/^[[:space:]]*pkgver = //p' "$dir/.SRCINFO")" == "$pkgver" ]] || fail "electron $major metadata pkgver mismatch"
      [[ "$actual" == "$metadata" ]] || fail "electron $major .SRCINFO does not match PKGBUILD"
      [[ "$actual" != *electron42-castlab* ]] || fail "electron $major incorrectly provides Electron 42"
      [[ "$actual" == *"electron-castlab=$pkgver"* ]] || fail "electron $major lost generic alias"
      if [[ "$major" == 40 ]]; then
        [[ ${#provides[@]} -eq 1 ]] || fail 'Electron 40 has extra provides aliases'
      else
        [[ ${#provides[@]} -eq 2 && "$actual" == *"electron41-castlab=$pkgver"* ]] || fail 'Electron 41 missing correct versioned alias'
      fi
    )
  done
  echo 'PASS electron aliases (correct runtime, updated release, .SRCINFO agrees)'
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

@test "1Password updater preserves recipes after failed verification" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/pkg"
  cat >"$tmp/bin/wget" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -q && "$2" == -O ]] || exit 12
[[ "$4" != *"op_linux_${FAIL_WGET:-unlikely}_"* ]] || exit 42
printf 'fake zip data for %s' "$4" >"$3"
MOCK
  cat >"$tmp/bin/unzip" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -p && -f "$2" ]] || exit 12
[[ "$2" != *"op_linux_${FAIL_UNZIP:-unlikely}_"* ]] || exit 43
case "$3" in
  op) printf binary ;;
  op.sig) printf signature ;;
  *) exit 44 ;;
esac
MOCK
  cat >"$tmp/bin/gpgv" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -q && -s "$2" && -s "$3" ]] || exit 12
[[ "${FAIL_SIG:-0}" != 1 ]] || exit 45
MOCK
  chmod +x "$tmp/bin/"*
  cat >"$tmp/pkg/PKGBUILD" <<'RECIPE'
pkgname=1password-cli-bin
pkgver=2.42.0
pkgrel=1
sha256sums_x86_64=('old')
sha256sums_i686=('old')
sha256sums_arm=('old')
sha256sums_armv6h=('old')
sha256sums_aarch64=('old')
RECIPE
  printf precious >"$tmp/pkg/operations-notes.txt"
  printf precious2 >"$tmp/pkg/op-cache.txt"
  cp "$tmp/pkg/PKGBUILD" "$tmp/initial"

  for failure in wget unzip sig; do
    if (
      cd "$tmp/pkg"
      export PATH="$tmp/bin:$PATH" PKGVER=2.43.0
      case "$failure" in
        wget) export FAIL_WGET=arm ;;
        unzip) export FAIL_UNZIP=amd64 ;;
        sig) export FAIL_SIG=1 ;;
      esac
      bash "$root/packages/1password-cli-bin/package-update.sh" >"$tmp/log" 2>&1
    ); then
      fail "updater succeeded after $failure failure"
    fi
    cmp -s "$tmp/initial" "$tmp/pkg/PKGBUILD" || fail "updater changed recipe after $failure failure"
    [[ "$(cat "$tmp/pkg/operations-notes.txt")" == precious && "$(cat "$tmp/pkg/op-cache.txt")" == precious2 ]] || fail 'updater deleted unrelated files'
  done

  (
    cd "$tmp/pkg"
    PATH="$tmp/bin:$PATH" PKGVER=2.43.0 bash "$root/packages/1password-cli-bin/package-update.sh"
  ) || fail 'successful updater run failed'
  grep -qx 'pkgver=2.43.0' "$tmp/pkg/PKGBUILD" || fail 'pkgver not updated'
  for arch in x86_64 i686 arm armv6h aarch64; do
    grep -Eq "^sha256sums_$arch=\('[0-9a-f]{64}'\)$" "$tmp/pkg/PKGBUILD" || fail "checksum not updated: $arch"
  done
  [[ "$(cat "$tmp/pkg/operations-notes.txt")" == precious && "$(cat "$tmp/pkg/op-cache.txt")" == precious2 ]] || fail 'updater deleted unrelated files on success'
  echo 'PASS onepassword_update (failures preserve files; success updates checksums)'
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

@test "Flutter artifact updater rejects missing or failed metadata without changing the recipe" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/src/flutter/bin/internal" "$tmp/src/dart/dart-sdk"
  printf '_dartver="old"\n_enginever=old\n_materialfontsver=old\n_gradlewver=old\n' >"$tmp/PKGBUILD"
  cp "$tmp/PKGBUILD" "$tmp/original"

  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -ofC ]]
MOCK
  cat >"$tmp/bin/cat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${CAT_MODE:-ok}" == partial && "${1:-}" == */material_fonts.version ]]; then
  printf 'a/b/c/incomplete\n'
  exit 47
fi
exec /usr/bin/cat "$@"
MOCK
  chmod +x "$tmp/bin/"*

  printf 'new-engine\n' >"$tmp/src/flutter/bin/internal/engine.version"
  printf 'a/b/c/new-fonts\n' >"$tmp/src/flutter/bin/internal/material_fonts.version"
  printf 'a/b/new-gradle\n' >"$tmp/src/flutter/bin/internal/gradle_wrapper.version"

  # SDK metadata is missing even though earlier fields were readable.
  if (cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$root/packages/flutter/update-artifact-versions.sh") >"$tmp/log" 2>&1; then
    fail 'Flutter updater accepted missing Dart SDK metadata'
  fi
  cmp -s "$tmp/PKGBUILD" "$tmp/original" ||
    fail 'missing Dart SDK version changed PKGBUILD'

  printf '3.11.0\n' >"$tmp/src/dart/dart-sdk/version"

  # A pipeline producing partial output then failing must not reach sed.
  if (cd "$tmp" && CAT_MODE=partial PATH="$tmp/bin:$PATH" bash "$root/packages/flutter/update-artifact-versions.sh") >"$tmp/log" 2>&1; then
    fail 'Flutter updater accepted failed material-font metadata read'
  fi
  cmp -s "$tmp/PKGBUILD" "$tmp/original" ||
    fail 'failed material-font metadata read changed PKGBUILD'

  : >"$tmp/src/flutter/bin/internal/engine.version"
  if (cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$root/packages/flutter/update-artifact-versions.sh") >"$tmp/log" 2>&1; then
    fail 'Flutter updater accepted an empty engine version'
  fi
  cmp -s "$tmp/PKGBUILD" "$tmp/original" ||
    fail 'empty engine version changed PKGBUILD'

  printf 'new-engine\n' >"$tmp/src/flutter/bin/internal/engine.version"
  (cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$root/packages/flutter/update-artifact-versions.sh") >"$tmp/log" 2>&1 ||
    fail "Flutter updater rejected valid metadata: $(cat "$tmp/log")"
  grep -qx '_dartver="3.11.0"' "$tmp/PKGBUILD" || fail 'Dart version was not updated'
  grep -qx '_enginever=new-engine' "$tmp/PKGBUILD" || fail 'engine version was not updated'
  grep -qx '_materialfontsver=new-fonts' "$tmp/PKGBUILD" || fail 'material fonts were not updated'
  grep -qx '_gradlewver=new-gradle' "$tmp/PKGBUILD" || fail 'Gradle wrapper was not updated'
  )
}
