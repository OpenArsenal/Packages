#!/usr/bin/env bats
# package selection integration tests — existing behavior retained.
# Each test is independently isolated by bats-core; fixture subshells preserve
# the original EXIT-trap cleanup semantics.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Installed-package selection preserves saved list on failures" {
  (
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
}

@test "Incomplete selection files and recipe outputs fail atomically" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/packages/demo"
  touch "$tmp/packages/demo/PKGBUILD"
  printf 'pkgbase = demo\n\tpkgname = demo\n' >"$tmp/packages/demo/.SRCINFO"
  source "$root/.mise/lib/pkg/list.sh"
  source "$root/.mise/lib/pkg/metadata.sh"

  printf '  # comment\r\n  demo  # selected\r\n\nother\n' >"$tmp/.packages"
  local -a selected=(sentinel)
  pkg::load_requested "$tmp/.packages" selected || fail 'valid selection list rejected'
  [[ "${selected[*]}" == 'demo other' ]] ||
    fail 'valid selection comments and whitespace parsed incorrectly'

  # Simulate tools that emit a partial list before failing. These failures
  # must not mutate the caller's selection even when some lines were printed.
  sed() { printf 'demo\n'; return 47; }
  selected=(sentinel)
  if pkg::load_requested "$tmp/.packages" selected >"$tmp/log" 2>&1; then
    fail 'selection accepted partial output from failed sed'
  fi
  [[ "${selected[*]}" == sentinel ]] || fail 'failed sed changed loaded selection'
  unset -f sed

  awk() { printf 'demo\n'; return 48; }
  if pkg::load_requested "$tmp/.packages" selected >"$tmp/log" 2>&1; then
    fail 'selection accepted partial output from failed awk'
  fi
  [[ "${selected[*]}" == sentinel ]] || fail 'failed awk changed loaded selection'
  unset -f awk

  : >"$tmp/.packages"
  pkg::load_requested "$tmp/.packages" selected || fail 'empty selection list rejected'
  [[ "${#selected[@]}" -eq 0 ]] || fail 'empty selection contained a phantom package'
  pkg::load_requested "$tmp/not-present" selected || fail 'missing selection file rejected'
  [[ "${#selected[@]}" -eq 0 ]] || fail 'missing selection file did not clear selection'

  pkg::metadata_outputs() {
    printf 'demo\n'
    [[ "${OUTPUT_MODE:-ok}" != partial ]] || return 49
  }
  pacman() {
    case "$1" in
      -Sl) return 0 ;;
      -Qq) printf 'demo\n' ;;
      -Qi|-Si) printf 'Packager : Fixture Packager\n' ;;
      *) return 2 ;;
    esac
  }

  selected=(sentinel)
  if OUTPUT_MODE=partial pkg::installed_selected "$tmp/packages" demo selected >"$tmp/log" 2>&1; then
    fail 'installed selection accepted partially failed metadata outputs'
  fi
  [[ "${selected[*]}" == sentinel ]] || fail 'partial package metadata changed selected outputs'
  grep -q 'unable to read package outputs' "$tmp/log" ||
    fail 'partial package metadata diagnostic disappeared'

  OUTPUT_MODE=ok pkg::installed_selected "$tmp/packages" demo selected ||
    fail 'valid installed selection rejected'
  [[ "${selected[*]}" == demo ]] || fail 'valid installed selection did not choose demo'

  echo 'PASS selection_input_failures (partial list and recipe reads fail without changing selection)'
  )
}

