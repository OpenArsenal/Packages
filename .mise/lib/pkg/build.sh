# shellcheck shell=bash

pkg::pacman_can_resolve() {
  local spec="$1"

  # --nodeps twice disables dependency checks while still requiring the target
  # package itself to exist in an enabled sync repository.
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
    --cleanbuild
  )

  echo "==> Building: $pkg_dir" >&2

  (
    cd "$pkg_dir" || exit 1
    export PKGDEST="${REPO_DIR:?REPO_DIR not set}"
    export LOGDEST="$PWD/logs"
    mkdir -p "$LOGDEST"

    makechrootpkg "${chroot_args[@]}" -- "${makepkg_args[@]}" || {
      rc=$?
      echo "error: makechrootpkg failed for: ${pkg_dir##*/} (exit $rc)" >&2
      return "$rc"
    }
  )
}

pkg::publish_outputs() {
  local pkg_dir="$1"
  local version output matched
  local -a archives=()
  local -a matches=()
  local found=false

  version="$(pkg::metadata_version "$pkg_dir")" || {
    echo "error: unable to determine package version for: ${pkg_dir##*/}" >&2
    return 1
  }

  while IFS= read -r output; do
    [[ -n "$output" ]] || continue
    found=true

    if ! matched="$(repo::match_package_archives "$REPO_DIR" "$output" "$version")"; then
      echo "error: unable to inspect built package archives for: $output" >&2
      return 1
    fi

    matches=()
    if [[ -n "$matched" ]]; then
      mapfile -t matches <<<"$matched"
    fi

    if (( ${#matches[@]} == 0 )); then
      echo "error: build completed but no $version archive found for: $output" >&2
      return 1
    fi

    if (( ${#matches[@]} > 1 )); then
      echo "error: multiple $version archives found for: $output" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
    fi

    echo "==> Publishing: $output" >&2
    archives+=("${matches[0]}")
  done < <(pkg::metadata_outputs "$pkg_dir")

  [[ "$found" == "true" ]] || {
    echo "error: no package outputs declared for: ${pkg_dir##*/}" >&2
    return 1
  }

  if ! repo::add_archives "$REPO_DB" false false false "${archives[@]}"; then
    echo "error: failed to publish package outputs for: ${pkg_dir##*/}" >&2
    return 1
  fi
}
