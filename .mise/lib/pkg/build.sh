# shellcheck shell=bash

pkg::pacman_has() {
  local dep="$1"
  pacman -Si "$dep" >/dev/null 2>&1
}

pkg::validate_dir() {
  local pkg_dir="$1"

  [[ -d "$pkg_dir" ]] || {
    echo "error: package directory not found: $pkg_dir" >&2
    return 1
  }

  [[ -f "$pkg_dir/PKGBUILD" ]] || {
    echo "error: PKGBUILD not found: $pkg_dir/PKGBUILD" >&2
    return 1
  }
}

pkg::build_dir() {
  local pkg_dir="$1"

  pkg::validate_dir "$pkg_dir" || return

  echo "==> Building: $pkg_dir" >&2

  (
    cd "$pkg_dir" || exit 1
    export PKGDEST="${REPO_DIR:?REPO_DIR not set}"
    export LOGDEST="$PWD/logs"
    mkdir -p "$LOGDEST"

    makechrootpkg -r "${CHROOT_DIR:?CHROOT_DIR not set}" -c -u -x failure \
      -- --syncdeps --cleanbuild --noconfirm --log
  )
}

pkg::publish_outputs() {
  local pkg_dir="$1"
  local output

  while IFS= read -r output; do
    [[ -n "$output" ]] || continue
    repo::update_db "$REPO_DIR" "$REPO_DB" "$output" false false false
  done < <(pkg::metadata_outputs "$pkg_dir")
}
