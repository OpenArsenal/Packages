#!/usr/bin/env bats
# Integration checks for destructive tasks and their fail-safe boundaries.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Chroot deletion rejects unsafe paths and permits only a direct child of the configured base" {
  (
  local tmp invalid
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/base/build" "$tmp/outside"
  ln -s "$tmp/outside" "$tmp/base/escape"
  export CHROOT_BASE="$tmp/base" CHROOT_DIR="$tmp/base/build"

  source "$root/.mise/lib/task.sh"
  source "$root/.mise/lib/chroot.sh"

  # Only permit fixture deletion, even if a safety check regresses.
  task::run_root() {
    printf '%s\n' "$*" >>"$tmp/root-called"
    [[ "$*" == "rm -rf -- $tmp/base/build" ]] || return 77
    rm -rf -- "$tmp/base/build"
  }

  for invalid in / . "$tmp/base" "$tmp/outside/build" "$tmp/base/../outside/build" "$tmp/base/escape/build"; do
    rm -f "$tmp/root-called"
    if CHROOT_DIR="$invalid" chroot::destroy >"$tmp/log" 2>&1; then
      fail "unsafe chroot path was accepted: $invalid"
    fi
    [[ ! -e "$tmp/root-called" && -d "$tmp/base/build" ]] ||
      fail "unsafe chroot path reached root deletion: $invalid"
  done

  rm -f "$tmp/root-called"
  if CHROOT_BASE=/ CHROOT_DIR="$tmp/base/build" chroot::destroy >"$tmp/log" 2>&1; then
    fail 'chroot deletion accepted a root-level base'
  fi
  [[ ! -e "$tmp/root-called" && -d "$tmp/base/build" ]] ||
    fail 'root-level base reached root deletion'

  chroot::destroy || fail 'safe direct-child chroot deletion failed'
  [[ ! -e "$tmp/base/build" ]] || fail 'safe chroot deletion left the build directory'
  [[ "$(cat "$tmp/root-called")" == "rm -rf -- $tmp/base/build" ]] ||
    fail 'safe chroot deletion targeted the wrong path'
  )
}

@test "AUR import preserves an existing recipe until a valid replacement is staged" {
  (
  local tmp target
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/demo"
  export PKGBUILDS_ROOT="$root" PACKAGES_DIR="$tmp/packages" TEST_TMP="$tmp"
  export PATH="$tmp/bin:$PATH" usage_packages="'demo'" usage_source=auto usage_force=true
  target="$PACKAGES_DIR/demo"
  printf 'original recipe\n' >"$target/PKGBUILD"

  cat >"$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == clone && "$2" == --depth && "$3" == 1 && "$4" == -- ]] || exit 90
url="$5"
target="$6"
printf '%s\n' "$url" >>"$TEST_TMP/git-called"
mkdir -p "$target"
case "${GIT_MODE:-ok}" in
  fail)
    printf 'partial recipe\n' >"$target/PKGBUILD"
    exit 47
    ;;
  no-recipe)
    printf 'not a recipe\n' >"$target/README"
    exit 0
    ;;
  fallback)
    if [[ "$url" == https://aur.archlinux.org/* ]]; then
      printf 'partial recipe\n' >"$target/PKGBUILD"
      exit 48
    fi
    ;;
esac
printf 'pkgname=demo\npkgver=2\n' >"$target/PKGBUILD"
mkdir -p "$target/.git"
MOCK
  chmod +x "$tmp/bin/git"

  rm -f "$tmp/git-called"
  if GIT_MODE=ok usage_force=false bash "$root/.mise/tasks/aur/import" >"$tmp/log" 2>&1; then
    fail 'import overwrote existing recipe without --force'
  fi
  [[ ! -e "$tmp/git-called" && "$(cat "$target/PKGBUILD")" == 'original recipe' ]] ||
    fail 'import attempted clone or modified recipe without --force'

  local mode
  for mode in fail no-recipe; do
    if GIT_MODE="$mode" bash "$root/.mise/tasks/aur/import" >"$tmp/log" 2>&1; then
      fail "import accepted a $mode staging result"
    fi
    [[ "$(cat "$target/PKGBUILD")" == 'original recipe' ]] ||
      fail "import lost original recipe after $mode"
  done

  GIT_MODE=fallback bash "$root/.mise/tasks/aur/import" >"$tmp/log" 2>&1 ||
    fail "AUR-to-Arch fallback did not import a valid recipe: $(cat "$tmp/log")"
  [[ "$(cat "$target/PKGBUILD")" == $'pkgname=demo\npkgver=2' ]] ||
    fail 'valid clone did not replace the prior recipe'
  [[ ! -e "$target/.git" ]] || fail 'import retained transient Git metadata'
  [[ -z "$(find "$PACKAGES_DIR" -maxdepth 1 -name '.import.*' -print)" ]] ||
    fail 'import left a staging directory behind'
  )
}
