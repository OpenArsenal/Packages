# shellcheck shell=bash

pkg::pacman_has() {
  local dep="$1"
  pacman -Si "$dep" >/dev/null 2>&1
}

pkg::build_pkgdir() {
  local pkg_dir="$1"
  echo "Building: $pkg_dir" >&2
  pushd "$pkg_dir" >/dev/null || return
  mise run pkg:build
  popd >/dev/null || return
}

pkg::validate_pkg_dir() {
  local pkg_dir="$1"
  if [[ ! -d "$pkg_dir" ]]; then
    echo "warning: package directory not found; skipping: $pkg_dir" >&2
    return 1
  fi
  if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
    echo "warning: missing PKGBUILD; skipping: $pkg_dir" >&2
    return 1
  fi
  return 0
}
