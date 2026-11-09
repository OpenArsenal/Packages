#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { echo "FAIL: $*" >&2; exit 1; }

prune() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/repo"
  export TEST_TMP="$tmp" PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/test.db"
  export PATH="$tmp/bin:$PATH"

  cat > "$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$BSDTAR_MODE:$1" in
  list-fail:-tf) exit 41 ;;
  list-partial-fail:-tf) echo 'kept/desc'; exit 41 ;;
  extract-fail:-xOf) exit 42 ;;
  extract-partial-fail:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n'; exit 42 ;;
  *:-tf) echo 'kept/desc' ;;
  missing-filename:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n' ;;
  *:-xOf) printf '%%FILENAME%%\nkept-1-1-x86_64.pkg.tar.zst\n\n%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat > "$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Qp && "$2" == -- ]] || exit 2
case "${3##*/}" in
  kept-*) echo 'kept 1-1' ;;
  orphan-*) echo 'orphan 1-1' ;;
  *) exit 2 ;;
esac
MOCK
  cat > "$tmp/bin/paccache" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/paccache-called"
[[ " $* " == *' -d '* && " $* " == *' -v '* ]] || exit 88
if [[ "${PACCACHE_MODE:-ok}" == fail ]]; then
  echo 'kept-1-1-x86_64.pkg.tar.zst'
  exit 43
fi
printf '==> Candidate packages:\nkept-0-1-x86_64.pkg.tar.zst\nkept-1-1-x86_64.pkg.tar.zst\n'
MOCK
  chmod +x "$tmp/bin/"*
  touch "$REPO_DB" "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst" "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst.sig" \
    "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst.sig"

  for mode in list-fail list-partial-fail extract-fail extract-partial-fail missing-filename; do
    if BSDTAR_MODE="$mode" bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
      fail "prune succeeded after $mode"
    fi
    [[ -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst" && -f "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" ]] || fail "prune deleted archives after $mode"
    [[ -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst.sig" && -f "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst.sig" ]] || fail "prune deleted signatures after $mode"
    [[ ! -e "$tmp/paccache-called" ]] || fail "paccache ran after $mode"
  done

  if BSDTAR_MODE=ok PACCACHE_MODE=fail bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
    fail 'prune succeeded after paccache failed'
  fi
  [[ -f "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" ]] || fail 'paccache failure removed orphan'

  BSDTAR_MODE=ok bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 || fail "successful prune failed: $(cat "$tmp/log")"
  [[ -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst" && -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst.sig" ]] || fail 'prune removed indexed package'
  [[ ! -e "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" && ! -e "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst.sig" ]] || fail 'prune did not remove orphan'
  [[ -f "$tmp/paccache-called" ]] || fail 'paccache not called on success'
  for ver in 0 2 3; do
    touch "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst" "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst.sig"
  done

  BSDTAR_MODE=ok usage_dry_run=true bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 || fail 'prune dry-run failed'
  grep -q 'kept-0-1-x86_64.pkg.tar.zst' "$tmp/log" || fail 'old archive missing from dry-run'
  ! grep -q 'kept-1-1-x86_64.pkg.tar.zst' "$tmp/log" || fail 'published archive listed for deletion'
  [[ -f "$REPO_DIR/kept-0-1-x86_64.pkg.tar.zst" ]] || fail 'dry-run deleted archive'

  BSDTAR_MODE=ok bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 || fail 'version retention prune failed'
  [[ ! -e "$REPO_DIR/kept-0-1-x86_64.pkg.tar.zst" && ! -e "$REPO_DIR/kept-0-1-x86_64.pkg.tar.zst.sig" ]] || fail 'old unindexed version not removed'
  for ver in 1 2 3; do
    [[ -f "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst" && -f "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst.sig" ]] || fail "published or newer archive deleted: $ver"
  done
  echo 'PASS prune (reader failures, published version retained, old archive deleted, dry-run)'
)


metadata() (
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


publish() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"
  repo-add() {
    if [[ "$1" == --help ]]; then echo '--wait-for-lock'; return 0; fi
    printf '%s\n' "$*" >"$tmp/repo-add-args"
    [[ "${REPO_ADD_MODE:-ok}" == ok ]] || return 42
  }
  repo::index_reset() { touch "$tmp/index-reset"; }

  if REPO_ADD_MODE=fail repo::add_archives "$tmp/db" false false false "$tmp/demo.pkg.tar.zst"; then
    fail 'repo-add failure was reported as success'
  else
    [[ "$?" -eq 42 ]] || fail 'repo-add failure status was lost'
  fi
  [[ ! -e "$tmp/index-reset" ]] || fail 'index reset after failed repo-add'

  repo::add_archives "$tmp/db" false false false "$tmp/demo.pkg.tar.zst" || fail 'repo-add success failed'
  [[ -f "$tmp/index-reset" ]] || fail 'index was not reset after successful repo-add'
  grep -q -- '--wait-for-lock' "$tmp/repo-add-args" || fail 'repo-add wait-for-lock behavior changed'
  echo 'PASS publish (repo-add failure propagates; successful add resets cache)'
)


build() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export TMPDIR="$tmp" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/db" CHROOT_DIR="$tmp/chroot" REPO_NAME=test
  mkdir -p "$REPO_DIR" "$CHROOT_DIR" "$tmp/demo"
  touch "$tmp/demo/PKGBUILD"
  printf 'pkgbase = demo\n\tpkgver = 1\n\tpkgrel = 1\n\n pkgname = demo\n' >"$tmp/demo/.SRCINFO"
  touch "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst"

  source "$root/.mise/lib/pkg/metadata.sh"
  source "$root/.mise/lib/pkg/build.sh"
  source "$root/.mise/lib/pkg/resolver.sh"
  source "$root/.mise/lib/repo/update.sh"

  PKG_PLAN=("$tmp/demo")
  makechrootpkg() {
    case "${BUILD_MODE:-new}" in
      new) touch "$REPO_DIR/demo-2-1-x86_64.pkg.tar.zst" ;;
      same) touch "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst" ;;
      none) : ;;
      fail) return 7 ;;
    esac
  }
  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "${3##*/}" in
      demo-1-1-*) echo 'demo 1-1' ;;
      demo-2-1-*) echo 'demo 2-1' ;;
      *) return 2 ;;
    esac
  }
  repo-add() {
    if [[ "$1" == --help ]]; then echo '--wait-for-lock'; return 0; fi
    printf '%s\n' "$@" >"$tmp/published"
  }
  repo::refresh_sync_db() { touch "$tmp/sync-refreshed"; }

  BUILD_MODE=new pkg::build_plan >"$tmp/log" 2>&1 || fail "new version build failed: $(cat "$tmp/log")"
  grep -qF "$REPO_DIR/demo-2-1-x86_64.pkg.tar.zst" "$tmp/published" || fail 'new build version not published'
  ! grep -qF "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst" "$tmp/published" || fail 'stale version published'
  [[ -f "$tmp/sync-refreshed" ]] || fail 'sync refresh was skipped'
  [[ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -print)" ]] || fail 'build marker leaked on success'

  rm -f -- "$tmp/published" "$REPO_DIR/demo-2-1-x86_64.pkg.tar.zst"
  if BUILD_MODE=none pkg::build_plan >"$tmp/log" 2>&1; then
    fail 'build without a new archive published a stale one'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'stale archive sent to repo-add'
  [[ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -print)" ]] || fail 'build marker leaked on failed publish'

  BUILD_MODE=same pkg::build_plan >"$tmp/log" 2>&1 || fail "same-version rebuild failed: $(cat "$tmp/log")"
  grep -qF "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst" "$tmp/published" || fail 'same-version rebuild not published'

  rm -f -- "$tmp/published"
  if BUILD_MODE=fail pkg::build_plan >"$tmp/log" 2>&1; then
    fail 'failed build reported as success'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'failed build still published'
  [[ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -print)" ]] || fail 'build marker leaked on failed build'
  echo 'PASS build (new Git version, stale archive, same-version rebuild, failed build)'
)

deps() (
  source "$root/.mise/lib/spec.sh"
  source "$root/.mise/lib/pkg/resolver.sh"
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  REPO_DIR="$tmp/repo"
  pkg::metadata_deps() { echo 'nodejs>=22.12.0'; }
  pkg::dir_outputs_name() { return 1; }
  repo::is_dep_satisfied() { printf '%s|%s|%s\n' "$2" "$3" "$4" >"$tmp/check"; }
  pkg::plan_deps "$tmp/demo" demo || fail 'dependency planning failed'
  [[ "$(cat "$tmp/check")" == 'nodejs|>=|22.12.0' ]] || fail 'planner omitted dependency constraint'
  echo 'PASS deps (planner preserves dependency constraints)'
)

clean_sources() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/empty" "$tmp/empty/not-a-recipe"
  export PKGBUILDS_ROOT="$root" REPO_DB="$tmp/repo.db" REPO_NAME=test PATH="$tmp/bin:$PATH" TEST_TMP="$tmp"
  touch "$REPO_DB"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -tf) echo 'kept/desc' ;;
  -xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/repo-remove" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_TMP/removed"
MOCK
  chmod +x "$tmp/bin/"*

  for sources in "$tmp/missing" "$tmp/empty"; do
    if PACKAGES_DIR="$sources" bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1; then
      fail "cleanup accepted a missing or empty source directory: $sources"
    fi
    [[ ! -e "$tmp/removed" ]] || fail 'cleanup modified repository with no recipes'
  done

  mkdir -p "$tmp/empty/kept"
  touch "$tmp/empty/kept/PKGBUILD"
  printf 'pkgbase = kept\n\tpkgname = kept\n' >"$tmp/empty/kept/.SRCINFO"
  PACKAGES_DIR="$tmp/empty" bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1 || fail "valid cleanup failed: $(cat "$tmp/log")"
  [[ ! -e "$tmp/removed" ]] || fail 'cleanup removed a referenced package'
  grep -q 'already matches' "$tmp/log" || fail 'cleanup did not recognize a matching repository'

  for mode in empty missing-pkgname; do
    if [[ "$mode" == empty ]]; then
      : >"$tmp/empty/kept/.SRCINFO"
    else
      printf 'pkgbase = kept\n\tpkgver = 1\n' >"$tmp/empty/kept/.SRCINFO"
    fi
    if PACKAGES_DIR="$tmp/empty" usage_dry_run=true bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1; then
      fail "cleanup accepted $mode .SRCINFO"
    fi
    grep -Fq "$tmp/empty/kept" "$tmp/log" || fail "missing offending path for $mode"
    [[ ! -e "$tmp/removed" ]] || fail "cleanup modified repository with $mode metadata"
  done
  echo 'PASS clean_sources (missing source, empty metadata, valid source)'
)

clean_db() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/kept"
  export PKGBUILDS_ROOT="$root" REPO_DB="$tmp/repo.db" REPO_NAME=test
  export PACKAGES_DIR="$tmp/packages" PATH="$tmp/bin:$PATH" TEST_TMP="$tmp"
  touch "$REPO_DB" "$PACKAGES_DIR/kept/PKGBUILD"
  printf 'pkgbase = kept\n\tpkgname = kept\n' >"$PACKAGES_DIR/kept/.SRCINFO"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "${BSDTAR_MODE:-ok}:$1" in
  list-fail:-tf) exit 41 ;;
  list-partial-fail:-tf) echo 'kept/desc'; exit 41 ;;
  extract-fail:-xOf) exit 42 ;;
  extract-partial-fail:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n'; exit 42 ;;
  *:-tf) printf 'kept/desc\nstale/desc\n' ;;
  *:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n%%NAME%%\nstale\n\n%%VERSION%%\n1-1\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/repo-remove" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_TMP/removed"
MOCK
  chmod +x "$tmp/bin/"*

  for mode in list-fail list-partial-fail extract-fail extract-partial-fail; do
    if BSDTAR_MODE="$mode" bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1; then
      fail "cleanup accepted failed database reader: $mode"
    fi
    [[ ! -e "$tmp/removed" ]] || fail "cleanup modified DB after $mode"
    ! grep -q 'already matches' "$tmp/log" || fail "cleanup reported success after $mode"
  done

  usage_dry_run=true bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1 || fail 'cleanup dry-run failed'
  [[ "$(cat "$tmp/log")" == stale ]] || fail 'cleanup dry-run listed unexpected entries'
  [[ ! -e "$tmp/removed" ]] || fail 'cleanup dry-run modified database'
  bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1 || fail 'cleanup failed with readable database'
  [[ "$(tail -n1 "$tmp/removed")" == stale ]] || fail 'cleanup did not remove only stale entry'
  ! grep -q '^kept$' "$tmp/removed" || fail 'cleanup removed an indexed package'
  echo 'PASS clean_db (failed reads abort; dry-run and valid stale removal preserved)'
)

electron_aliases() (
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

strict_skipped() (
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

srcinfo_consistency() (
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

onepassword_update() (
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

provider_versions() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/repo"
  export REPO_DB="$tmp/repo/test.db"
  touch "$REPO_DB"
  source "$root/.mise/lib/spec.sh"
  source "$root/.mise/lib/repo/inspect.sh"

  bsdtar() {
    case "$1" in
      -tf) printf 'electron40/desc\nelectron41/desc\n' ;;
      -xOf) cat <<'MOCK'
%NAME%
electron40-castlab
%VERSION%
40.10.6+wvcus
%PROVIDES%
electron-castlab=40.10.6+wvcus
plain-capability

%NAME%
electron41-castlab
%VERSION%
41.10.7+wvcus
%PROVIDES%
electron-castlab=41.10.7+wvcus
MOCK
      ;;
      *) return 2 ;;
    esac
  }
  vercmp() {
    [[ "$1" == "$2" ]] && { echo 0; return 0; }
    case "$1:$2" in
      40.*:41.*|40.*:42.*) echo -1 ;;
      41.*:40.*|41.*:39.*|40.*:39.*) echo 1 ;;
      *) echo "unexpected vercmp: $1 vs $2" >&2; return 3 ;;
    esac
  }

  repo::index_build "$tmp/repo" || fail 'provider index failed'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '=' '40.10.6+wvcus' || fail 'older exact provider rejected'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '<' '41.10.7+wvcus' || fail 'older provider failed upper bound'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '<=' '40.10.6+wvcus' || fail 'older provider failed inclusive upper bound'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '=' '41.10.7+wvcus' || fail 'newer exact provider rejected'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '>=' '41.10.7+wvcus' || fail 'newer provider failed lower bound'
  if repo::is_dep_satisfied "$tmp/repo" electron-castlab '<' '40.10.6+wvcus'; then
    fail 'accepted unsatisfied upper bound'
  fi
  if repo::is_dep_satisfied "$tmp/repo" electron-castlab '=' '39.0.0'; then
    fail 'accepted nonexistent provider version'
  fi
  repo::is_dep_satisfied "$tmp/repo" plain-capability '' '' || fail 'unversioned provider disappeared'
  if repo::is_dep_satisfied "$tmp/repo" plain-capability '>=' '40.10.6+wvcus'; then
    fail 'unversioned provider satisfied versioned requirement'
  fi
  repo::is_dep_satisfied "$tmp/repo" electron40-castlab '=' '40.10.6+wvcus' || fail 'package identity lookup changed'
  echo 'PASS provider_versions (multiple providers, exact and upper bounds)'
)

select_installed() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PACKAGES_FILE="$tmp/.packages" REPO_NAME=test PATH="$tmp/bin:$PATH"
  touch "$PACKAGES_DIR/demo/PKGBUILD"
  printf 'pkgbase = demo\n\tpkgname = demo\n' >"$PACKAGES_DIR/demo/.SRCINFO"
  printf 'existing-package\n# keep this comment\n' >"$PACKAGES_FILE"
  cp "$PACKAGES_FILE" "$tmp/original"

  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -Sl) exit 0 ;;
  -Qq)
    [[ "${QUERY_MODE:-ok}" != partial ]] || printf 'demo\n'
    [[ "${QUERY_MODE:-ok}" == ok ]] || exit 37
    printf 'demo\n'
    ;;
  -Si) printf 'Packager : Fixture Packager\n' ;;
  -Qi)
    case "${INFO_MODE:-ok}" in
      fail) printf 'Packager : partial\n'; exit 48 ;;
      missing) printf 'Name : demo\n' ;;
      *) printf 'Packager : Fixture Packager\n' ;;
    esac
    ;;
  *) exit 2 ;;
esac
MOCK
  chmod +x "$tmp/bin/pacman"

  for mode in empty partial; do
    if QUERY_MODE="$mode" bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1; then
      fail "selection succeeded after $mode installed-package query failure"
    fi
    cmp -s "$PACKAGES_FILE" "$tmp/original" || fail "selection changed after $mode query failure"
    ! grep -q '^Wrote' "$tmp/log" || fail 'failed selection reported a write'
  done

  if QUERY_MODE=partial usage_dry_run=true bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1; then
    fail 'selection dry-run accepted a failed installed-package query'
  fi
  cmp -s "$PACKAGES_FILE" "$tmp/original" || fail 'failed dry-run changed saved selection'

  : >"$tmp/not-a-directory"
  for invalid_dir in "$tmp/missing" "$tmp/not-a-directory"; do
    if PACKAGES_DIR="$invalid_dir" QUERY_MODE=ok bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1; then
      fail "selection accepted invalid source directory: $invalid_dir"
    fi
    cmp -s "$PACKAGES_FILE" "$tmp/original" || fail 'invalid source directory modified saved selection'
    grep -Fq "$invalid_dir" "$tmp/log" || fail 'invalid directory diagnostic omitted path'
  done

  for mode in fail missing; do
    if INFO_MODE="$mode" QUERY_MODE=ok bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1; then
      fail "selection accepted invalid installed metadata: $mode"
    fi
    cmp -s "$PACKAGES_FILE" "$tmp/original" || fail "invalid $mode metadata modified saved selection"
    grep -Fq 'demo' "$tmp/log" || fail "metadata error did not identify package: $mode"
  done

  if INFO_MODE=fail QUERY_MODE=ok usage_dry_run=true bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1; then
    fail 'selection dry-run accepted failed installed metadata'
  fi
  cmp -s "$PACKAGES_FILE" "$tmp/original" || fail 'failed metadata dry-run changed saved selection'

  QUERY_MODE=ok usage_dry_run=true bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1 || fail 'valid selection dry-run failed'
  [[ "$(cat "$tmp/log")" == demo ]] || fail 'dry-run did not list selected package'
  cmp -s "$PACKAGES_FILE" "$tmp/original" || fail 'successful dry-run changed saved selection'

  QUERY_MODE=ok bash "$root/.mise/tasks/pkg/select-installed" >"$tmp/log" 2>&1 || fail "successful selection failed: $(cat "$tmp/log")"
  [[ "$(cat "$PACKAGES_FILE")" == demo ]] || fail 'successful selection did not update saved list'
  echo 'PASS select_installed (failed queries and invalid source paths preserve saved list)'
)


planner_failures() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/missing.db"
  mkdir -p "$REPO_DIR" "$tmp/packages"
  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"

  recipe() {
    local name="$1" dependency="${2:-}"
    local dir="$tmp/packages/$name"
    mkdir -p "$dir"
    printf 'pkgname=%s\npkgver=1\npkgrel=1\n' "$name" >"$dir/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = %s\n' \
      "$name" "$name" >"$dir/.SRCINFO"
    [[ -z "$dependency" ]] || printf '\tdepends = %s\n' "$dependency" >>"$dir/.SRCINFO"
  }

  recipe missing missing-dep
  recipe good
  recipe cycle-a cycle-b
  recipe cycle-b cycle-a

  # Exercise the entire plan/build boundary without Arch or a real chroot.
  repo::is_dep_satisfied() { return 1; }
  pkg::pacman_can_resolve() { return 1; }
  pkg::build_plan() { touch "$tmp/build-ran"; }

  if pkg::build_selected "$tmp/packages" false missing good >"$tmp/log" 2>&1; then
    fail 'build proceeded after unresolved dependency'
  fi
  grep -q 'unresolved dependency' "$tmp/log" || fail 'missing dependency diagnostic disappeared'
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started after an unresolved dependency'

  if pkg::build_selected "$tmp/packages" false cycle-a >"$tmp/log" 2>&1; then
    fail 'build proceeded after dependency cycle'
  fi
  grep -q 'dependency cycle detected' "$tmp/log" || fail 'cycle diagnostic disappeared'
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started after a cycle'

  # A broken database must stop the build before metadata/dependency fallback.
  REPO_DB="$tmp/broken.db"
  touch "$REPO_DB"
  repo::index_reset
  bsdtar() { return 47; }
  if pkg::build_selected "$tmp/packages" false good >"$tmp/log" 2>&1; then
    fail 'build proceeded after repository index read failed'
  fi
  grep -q 'unable to inspect repository database' "$tmp/log" ||
    fail 'repository index failure diagnostic disappeared'
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started with unreadable repository index'

  REPO_DB="$tmp/missing.db"
  repo::index_reset
  pkg::cache_srcinfo() { return 47; }
  if pkg::build_selected "$tmp/packages" false good >"$tmp/log" 2>&1; then
    fail 'build proceeded after metadata indexing failed'
  fi
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started after metadata indexing failed'
  echo 'PASS planner_failures (unresolved deps, cycles, and unreadable metadata or index stop builds)'
)

archive_selection_errors() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/spec.sh"
  source "$root/.mise/lib/repo/inspect.sh"
  source "$root/.mise/lib/repo/update.sh"

  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "$3" in
      "$tmp/demo-1.pkg") printf 'demo 1-1\n' ;;
      "$tmp/demo-2.pkg") printf 'demo 2-1\n' ;;
      *) return 3 ;;
    esac
  }
  vercmp() {
    case "${VERCMP_MODE:-ok}" in
      fail) return 47 ;;
      malformed) printf 'invalid\n'; return 0 ;;
    esac
    [[ "$1:$2" == '2-1:1-1' || "$1:$2" == '2:1' ]] || return 48
    printf '1\n'
  }

  local -a selected=()
  repo::select_newest_archives selected "$tmp/demo-1.pkg" "$tmp/demo-2.pkg" ||
    fail 'valid version selection failed'
  [[ "${selected[*]}" == "$tmp/demo-2.pkg" ]] || fail 'newest archive not selected'

  local mode
  for mode in fail malformed; do
    if VERCMP_MODE="$mode" repo::select_newest_archives selected \
      "$tmp/demo-1.pkg" "$tmp/demo-2.pkg" >"$tmp/log" 2>&1; then
      fail "archive selection accepted $mode comparison"
    fi
  done

  REPO_DB="$tmp/db"
  touch "$REPO_DB"
  repo::db_records() { printf 'P\tdemo\t1\nP\tdemo\t2\n'; }
  if VERCMP_MODE=fail repo::index_build "$tmp/repo" >"$tmp/log" 2>&1; then
    fail 'repository index accepted a failed version comparison'
  fi
  [[ -z "$REPO_INDEX_DIR" && -z "${REPO_PACKAGE_VERSION[demo]+x}" ]] ||
    fail 'failed index retained partially parsed versions'
  if VERCMP_MODE=fail repo::is_dep_satisfied "$tmp/repo" demo '=' 1 >"$tmp/log" 2>&1; then
    fail 'partially built index satisfied a dependency'
  fi
  echo 'PASS archive_selection_errors (newest archive and failed comparisons)'
)


archive_enumeration_failure() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"

  repo::match_package_archives() {
    printf '%s\n' "$tmp/demo-1.pkg.tar.zst"
    [[ "${ENUM_MODE:-ok}" == ok ]] || return 47
  }
  repo::select_newest_archives() {
    local outvar_name="$1"
    shift
    local -n outvar="$outvar_name"
    outvar=("$@")
  }
  repo::add_archives() {
    printf '%s\n' "${@:5}" >"$tmp/published"
  }

  if ENUM_MODE=partial repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1; then
    fail 'repository update accepted partially failed archive enumeration'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'repository update published partial archive set'
  grep -q 'unable to enumerate package archives' "$tmp/log" ||
    fail 'archive enumeration failure diagnostic disappeared'

  ENUM_MODE=ok repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1 ||
    fail "successful archive enumeration was rejected: $(cat "$tmp/log")"
  [[ "$(cat "$tmp/published")" == "$tmp/demo-1.pkg.tar.zst" ]] ||
    fail 'successful archive enumeration was not published'
  echo 'PASS archive_enumeration_failure (partial scan aborts; successful scan publishes)'
)


versioned_local_providers() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/missing.db"
  mkdir -p "$REPO_DIR" "$tmp/packages"
  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"

  recipe() {
    local name="$1" dependency="${2:-}" provided="${3:-}"
    local dir="$tmp/packages/$name"
    mkdir -p "$dir"
    touch "$dir/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = %s\n' \
      "$name" "$name" >"$dir/.SRCINFO"
    [[ -z "$dependency" ]] || printf '\tdepends = %s\n' "$dependency" >>"$dir/.SRCINFO"
    [[ -z "$provided" ]] || printf '\tprovides = %s\n' "$provided" >>"$dir/.SRCINFO"
  }

  recipe consumer 'shared>=2'
  recipe impossible 'shared>=3'
  recipe provider-one '' 'shared=1'
  recipe provider-two '' 'shared=2'
  recipe provider-unversioned '' shared

  vercmp() {
    local a="$1" b="$2"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 48
    if (( a < b )); then printf '%s\n' -1
    elif (( a > b )); then printf '%s\n' 1
    else printf '%s\n' 0; fi
  }
  repo::is_dep_satisfied() { return 1; }
  pkg::pacman_can_resolve() { return 1; }

  pkg::plan_selected "$tmp/packages" false consumer >"$tmp/log" 2>&1 ||
    fail "compatible local provider was rejected: $(cat "$tmp/log")"
  [[ "${PKG_PLAN[*]}" == "$tmp/packages/provider-two $tmp/packages/consumer" ]] ||
    fail "versioned dependency selected wrong provider: ${PKG_PLAN[*]}"

  if pkg::plan_selected "$tmp/packages" false impossible >"$tmp/log" 2>&1; then
    fail 'incompatible local provider satisfied a versioned dependency'
  fi
  grep -q 'unresolved dependency' "$tmp/log" ||
    fail 'missing diagnostic for incompatible local provider'
  echo 'PASS versioned_local_providers (compatible alias selected, incompatible rejected)'
)

archive_metadata_failures() (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"

  repo::match_package_archives() {
    printf '%s\n' "$tmp/demo-1.pkg.tar.zst" "$tmp/demo-2.pkg.tar.zst"
  }
  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "${3##*/}" in
      demo-1.pkg.tar.zst) printf 'demo 1-1\n' ;;
      demo-2.pkg.tar.zst)
        case "${META_MODE:-ok}" in
          unreadable) return 45 ;;
          malformed) printf 'demo\n' ;;
          ok) printf 'demo 2-1\n' ;;
        esac
        ;;
      *) return 3 ;;
    esac
  }
  vercmp() {
    [[ "$1:$2" == '2-1:1-1' ]] || return 47
    printf '1\n'
  }
  repo::add_archives() {
    printf '%s\n' "${@:5}" >"$tmp/published"
  }

  local mode
  for mode in unreadable malformed; do
    rm -f -- "$tmp/published"
    if META_MODE="$mode" repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1; then
      fail "repository update accepted $mode package metadata"
    fi
    [[ ! -e "$tmp/published" ]] || fail "repository published a partial set after $mode metadata"
  done

  META_MODE=ok repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1 ||
    fail "valid package metadata rejected: $(cat "$tmp/log")"
  [[ "$(cat "$tmp/published")" == "$tmp/demo-2.pkg.tar.zst" ]] ||
    fail 'valid newest package was not selected'
  echo 'PASS archive_metadata_failures (unreadable metadata blocks publication)'
)

case "${1:-all}" in
  select_installed) select_installed ;;
  provider_versions) provider_versions ;;
  deps) deps ;;
  versioned_local_providers) versioned_local_providers ;;
  archive_metadata_failures) archive_metadata_failures ;;
  planner_failures) planner_failures ;;
  archive_selection_errors) archive_selection_errors ;;
  archive_enumeration_failure) archive_enumeration_failure ;;
  clean_sources) clean_sources ;;
  clean_db) clean_db ;;
  electron_aliases) electron_aliases ;;
  srcinfo_consistency) srcinfo_consistency ;;
  onepassword_update) onepassword_update ;;
  strict_skipped) strict_skipped ;;
  prune) prune ;;
  metadata) metadata ;;
  publish) publish ;;
  build) build ;;
  all) deps; versioned_local_providers; archive_metadata_failures; planner_failures; archive_selection_errors; archive_enumeration_failure; clean_sources; clean_db; prune; metadata; publish; build; electron_aliases; strict_skipped; srcinfo_consistency; onepassword_update; provider_versions; select_installed ;;
  *) fail "unknown test: $1" ;;
esac
