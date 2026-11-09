#!/usr/bin/env bats
# File-backed integration tests: discovery must finish before mutation.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Build log cleanup refuses a partial directory scan" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo/logs" "$tmp/packages/with spaces/logs"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PATH="$tmp/bin:$PATH"

  cat >"$tmp/bin/find" <<'MOCK'
#!/usr/bin/env bash
if [[ "${SCAN_MODE:-ok}" == partial ]]; then
  printf '%s\0' "$PACKAGES_DIR/demo/logs"
  exit 47
fi
exec /usr/bin/find "$@"
MOCK
  chmod +x "$tmp/bin/find"

  if SCAN_MODE=partial usage_force=true bash "$root/.mise/tasks/pkg/clean" >"$tmp/log" 2>&1; then
    fail 'forced log cleanup accepted a partial directory scan'
  fi
  [[ -d "$PACKAGES_DIR/demo/logs" && -d "$PACKAGES_DIR/with spaces/logs" ]] ||
    fail 'a failed scan deleted package logs'
  grep -Fq 'unable to enumerate package build logs' "$tmp/log" ||
    fail 'failed log scan did not explain the error'

  SCAN_MODE=ok usage_force=false bash "$root/.mise/tasks/pkg/clean" >"$tmp/log" 2>&1 ||
    fail 'valid log preview failed'
  [[ -d "$PACKAGES_DIR/demo/logs" && -d "$PACKAGES_DIR/with spaces/logs" ]] ||
    fail 'log preview deleted logs'
  SCAN_MODE=ok usage_force=true bash "$root/.mise/tasks/pkg/clean" >"$tmp/log" 2>&1 ||
    fail 'valid log cleanup failed'
  [[ ! -e "$PACKAGES_DIR/demo/logs" && ! -e "$PACKAGES_DIR/with spaces/logs" ]] ||
    fail 'valid cleanup left log directories behind'
  )
}

@test "Repository pruning refuses a partial archive scan" {
  (
  local tmp orphan
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/repo"
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/test.db"
  export PATH="$tmp/bin:$PATH"
  orphan="$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst"
  touch "$REPO_DB" "$orphan" "$orphan.sig"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -tf) printf 'kept/desc\n' ;;
  -xOf) printf '%%NAME%%\nkept\n%%VERSION%%\n1-1\n%%FILENAME%%\nkept-1-1-x86_64.pkg.tar.zst\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/paccache" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Qp && "$2" == -- ]] || exit 2
printf 'orphan 1-1\n'
MOCK
  cat >"$tmp/bin/find" <<'MOCK'
#!/usr/bin/env bash
if [[ "${SCAN_MODE:-ok}" == partial ]]; then
  printf '%s\0' "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst"
  exit 47
fi
exec /usr/bin/find "$@"
MOCK
  chmod +x "$tmp/bin/"*

  if SCAN_MODE=partial bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
    fail 'repository pruning accepted a partial archive scan'
  fi
  [[ -f "$orphan" && -f "$orphan.sig" ]] ||
    fail 'failed archive scan removed a package or its signature'
  grep -Fq 'unable to enumerate repository archives' "$tmp/log" ||
    fail 'failed archive scan did not explain the error'

  SCAN_MODE=ok bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 ||
    fail "valid repository prune failed: $(cat "$tmp/log")"
  [[ ! -e "$orphan" && ! -e "$orphan.sig" ]] ||
    fail 'valid repository prune left unindexed archive or signature'
  )
}

@test "Package update refuses partial nvchecker discovery and sorting" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" PACKAGES_FILE="$tmp/.packages"
  export TEST_TMP="$tmp" PATH="$tmp/bin:$PATH"
  touch "$PACKAGES_FILE" "$PACKAGES_DIR/demo/PKGBUILD" "$PACKAGES_DIR/demo/.nvchecker.toml"
  printf 'original metadata\n' >"$PACKAGES_DIR/demo/.SRCINFO"

  cat >"$tmp/bin/find" <<'MOCK'
#!/usr/bin/env bash
if [[ "${SCAN_MODE:-ok}" == partial ]]; then
  printf '%s\0' "$PACKAGES_DIR/demo/.nvchecker.toml"
  exit 47
fi
exec /usr/bin/find "$@"
MOCK
  cat >"$tmp/bin/sort" <<'MOCK'
#!/usr/bin/env bash
if [[ "${SORT_MODE:-ok}" == partial ]]; then
  cat
  exit 48
fi
exec /usr/bin/sort "$@"
MOCK
  cat >"$tmp/bin/pkgctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_TMP/pkgctl-ran"
MOCK
  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/makepkg-ran"
printf 'changed metadata\n'
MOCK
  chmod +x "$tmp/bin/"*

  local failure
  for failure in find sort; do
    rm -f "$tmp/pkgctl-ran" "$tmp/makepkg-ran"
    if [[ "$failure" == find ]]; then
      export SCAN_MODE=partial SORT_MODE=ok
    else
      export SCAN_MODE=ok SORT_MODE=partial
    fi
    if usage_apply=true bash "$root/.mise/tasks/pkg/update" >"$tmp/log" 2>&1; then
      fail "package update accepted partial $failure output"
    fi
    [[ ! -e "$tmp/pkgctl-ran" && ! -e "$tmp/makepkg-ran" ]] ||
      fail "package update ran tools after failed $failure scan"
    [[ "$(cat "$PACKAGES_DIR/demo/.SRCINFO")" == 'original metadata' ]] ||
      fail "failed $failure scan rewrote package metadata"
    grep -Fq 'unable to enumerate nvchecker configurations' "$tmp/log" ||
      fail "failed $failure scan did not explain the error"
  done

  SCAN_MODE=ok SORT_MODE=ok usage_apply=false bash "$root/.mise/tasks/pkg/update" >"$tmp/log" 2>&1 ||
    fail "valid nvchecker scan failed: $(cat "$tmp/log")"
  grep -Fq "version check $PACKAGES_DIR/demo" "$tmp/pkgctl-ran" ||
    fail 'valid nvchecker scan did not check selected package'
  [[ ! -e "$tmp/makepkg-ran" ]] || fail 'read-only check regenerated metadata'
  )
}
