# shellcheck shell=bash

pkg::pacman_can_resolve() {
  local spec="$1"

  pacman \
    --sync \
    --print \
    --print-format '%n' \
    --noconfirm \
    --nodeps \
    --nodeps \
    "$spec" >/dev/null 2>&1
}

pkg::resolve_dir() {
  local input="$1"
  local packages_dir="$2"
  local candidate

  if [[ -d "$input" ]]; then
    candidate="$input"
  elif [[ "$input" != */* && -d "$packages_dir/$input" ]]; then
    candidate="$packages_dir/$input"
  else
    echo "error: package not found: $input" >&2
    return 1
  fi

  (
    cd "$candidate" || exit 1
    pwd -P
  )
}

pkg::validate_dir() {
  local pkg_dir="$1"

  [[ -f "$pkg_dir/PKGBUILD" ]] || {
    echo "error: PKGBUILD not found: $pkg_dir/PKGBUILD" >&2
    return 1
  }
}

pkg::build_dir() {
  local pkg_dir="$1"

  pkg::validate_dir "$pkg_dir" || return

  local -a chroot_args=(
    -r "${CHROOT_DIR:?CHROOT_DIR not set}"
    -c
    -u
    -x failure
  )

  if [[ -d "${REPO_BASE:-}" ]]; then
    chroot_args+=(-D "$REPO_BASE")
  fi

  local -a makepkg_args=(
    --syncdeps
    --cleanbuild
    --noconfirm
    --log
  )

  echo "==> Building: $pkg_dir" >&2

  (
    cd "$pkg_dir" || exit 1
    export PKGDEST="${REPO_DIR:?REPO_DIR not set}"
    export LOGDEST="$PWD/logs"
    mkdir -p "$LOGDEST"

    makechrootpkg "${chroot_args[@]}" -- "${makepkg_args[@]}"
  )
}

pkg::publish_outputs() {
  local pkg_dir="$1"
  local output

  while IFS= read -r output; do
    [[ -n "$output" ]] || continue

    repo::update_db       "$REPO_DIR"       "$REPO_DB"       "$output"       false       false       false       false
  done < <(pkg::metadata_outputs "$pkg_dir")
}
