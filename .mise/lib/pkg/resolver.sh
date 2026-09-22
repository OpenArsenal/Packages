# shellcheck shell=bash

declare -Ag PKG_PROVIDER_DIR=()
declare -Ag PKG_STATE=()

pkg::index_register() {
  local name="$1"
  local pkg_dir="$2"
  local overwrite="${3:-false}"

  [[ -n "$name" ]] || return 0

  if [[ "$overwrite" == "true" || -z "${PKG_PROVIDER_DIR[$name]+x}" ]]; then
    PKG_PROVIDER_DIR["$name"]="$pkg_dir"
  fi
}

pkg::index_packages() {
  local packages_dir="$1"
  local pkg_dir name raw provide_name provide_op provide_ver

  PKG_PROVIDER_DIR=()
  PKG_STATE=()

  shopt -s nullglob

  # Real package names and directory/pkgbase names take precedence.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    pkg::index_register "${pkg_dir##*/}" "$pkg_dir" true
    pkg::index_register "$(pkg::metadata_pkgbase "$pkg_dir")" "$pkg_dir" true

    while IFS= read -r name; do
      pkg::index_register "$name" "$pkg_dir" true
    done < <(pkg::metadata_outputs "$pkg_dir")
  done

  # Virtual provides fill gaps but never replace a real package mapping.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    while IFS= read -r raw; do
      provide_name=""
      provide_op=""
      provide_ver=""
      pkg::spec_parse "$raw" provide_name provide_op provide_ver
      pkg::index_register "$provide_name" "$pkg_dir" false
    done < <(pkg::metadata_provides "$pkg_dir")
  done

  shopt -u nullglob
}

pkg::all_outputs_in_repo() {
  local pkg_dir="$1"
  local version output found=false

  version="$(pkg::metadata_version "$pkg_dir")" || return 1

  while IFS= read -r output; do
    [[ -n "$output" ]] || continue
    found=true
    repo::is_dep_satisfied "$REPO_DIR" "$output" "=" "$version" || return 1
  done < <(pkg::metadata_outputs "$pkg_dir")

  [[ "$found" == true ]]
}

pkg::ensure_deps_built() {
  local pkg_dir="$1"
  local pkg_label="$2"
  local raw dep op ver provider_dir

  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue

    dep=""
    op=""
    ver=""
    pkg::spec_parse "$raw" dep op ver
    [[ -n "$dep" ]] || continue

    if repo::is_dep_satisfied "$REPO_DIR" "$dep" "$op" "$ver"; then
      continue
    fi

    provider_dir="${PKG_PROVIDER_DIR[$dep]-}"
    if [[ -n "$provider_dir" ]]; then
      pkg::build_dir_with_deps "$provider_dir"

      if repo::is_dep_satisfied "$REPO_DIR" "$dep" "$op" "$ver"; then
        continue
      fi

      echo "error: local provider did not satisfy dependency for $pkg_label: $raw" >&2
      return 1
    fi

    if pkg::pacman_has "$dep"; then
      continue
    fi

    # Common virtual package exposed by systemd.
    if [[ "$dep" == "udev" ]] && pkg::pacman_has systemd; then
      continue
    fi

    echo "error: unresolved dependency for $pkg_label: $raw" >&2
    return 1
  done < <(pkg::metadata_deps "$pkg_dir")
}

pkg::build_dir_with_deps() {
  local pkg_dir="$1"
  local key pkgbase

  pkg::validate_dir "$pkg_dir" || return

  pkgbase="$(pkg::metadata_pkgbase "$pkg_dir")"
  key="${pkgbase:-${pkg_dir##*/}}"

  case "${PKG_STATE[$key]-}" in
    done) return 0 ;;
    visiting)
      echo "error: dependency cycle detected at package: $key" >&2
      return 1
      ;;
  esac

  PKG_STATE["$key"]="visiting"

  if pkg::all_outputs_in_repo "$pkg_dir"; then
    echo "==> Already current in repo: $key" >&2
    PKG_STATE["$key"]="done"
    return 0
  fi

  pkg::ensure_deps_built "$pkg_dir" "$key"
  pkg::build_dir "$pkg_dir"
  pkg::publish_outputs "$pkg_dir"

  PKG_STATE["$key"]="done"
}

pkg::build_with_deps() {
  local name="$1"
  local pkg_dir="${PKG_PROVIDER_DIR[$name]-}"

  if [[ -z "$pkg_dir" ]]; then
    echo "error: no local package provides: $name" >&2
    return 1
  fi

  pkg::build_dir_with_deps "$pkg_dir"
}

pkg::build_selected() {
  local packages_dir="$1"
  shift
  local -a requested=("$@")
  local entry pkg_dir

  pkg::index_packages "$packages_dir"

  for entry in "${requested[@]}"; do
    echo "==> Requested: $entry" >&2

    if [[ "$entry" = /* ]]; then
      pkg_dir="$entry"
      pkg::index_register "${pkg_dir##*/}" "$pkg_dir" true
      pkg::build_dir_with_deps "$pkg_dir"
    else
      pkg::build_with_deps "$entry"
    fi
  done
}
