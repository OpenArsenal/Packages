# shellcheck shell=bash

declare -Ag PKG_PROVIDER_DIR=()
declare -Ag PKG_STATE=()
declare -ag PKG_PLAN=()

pkg::resolver_reset() {
  PKG_PROVIDER_DIR=()
  PKG_STATE=()
  PKG_PLAN=()
}

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

  pkg::resolver_reset
  shopt -s nullglob

  # Repository directory names are explicit identities and always win.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue
    pkg::index_register "${pkg_dir##*/}" "$pkg_dir" true
  done

  # pkgbase/pkgname aliases fill only names that do not identify a directory.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    pkg::index_register "$(pkg::metadata_pkgbase "$pkg_dir")" "$pkg_dir"

    while IFS= read -r name; do
      pkg::index_register "$name" "$pkg_dir"
    done < <(pkg::metadata_outputs "$pkg_dir")
  done

  # provides= entries are lowest-priority aliases.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    while IFS= read -r raw; do
      provide_name=""
      provide_op=""
      provide_ver=""
      spec::parse "$raw" provide_name provide_op provide_ver
      pkg::index_register "$provide_name" "$pkg_dir"
    done < <(pkg::metadata_provides "$pkg_dir")
  done

  shopt -u nullglob
}

pkg::dir_outputs_name() {
  local pkg_dir="$1"
  local wanted="$2"
  local output

  while IFS= read -r output; do
    [[ "$output" == "$wanted" ]] && return 0
  done < <(pkg::metadata_outputs "$pkg_dir")

  return 1
}

pkg::all_outputs_in_repo() {
  local pkg_dir="$1"
  local version output
  local found=false

  version="$(pkg::metadata_version "$pkg_dir")" || return 1

  while IFS= read -r output; do
    [[ -n "$output" ]] || continue
    found=true
    repo::is_dep_satisfied "$REPO_DIR" "$output" "=" "$version" || return 1
  done < <(pkg::metadata_outputs "$pkg_dir")

  [[ "$found" == true ]]
}

pkg::plan_deps() {
  local pkg_dir="$1"
  local pkg_label="$2"
  local raw dep op ver provider_dir

  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue

    dep=""
    op=""
    ver=""
    spec::parse "$raw" dep op ver
    [[ -n "$dep" ]] || continue

    if pkg::dir_outputs_name "$pkg_dir" "$dep"; then
      continue
    fi

    if repo::is_dep_satisfied "$REPO_DIR" "$dep" "$op" "$ver"; then
      continue
    fi

    provider_dir="${PKG_PROVIDER_DIR[$dep]-}"
    if [[ -n "$provider_dir" ]]; then
      if [[ "$provider_dir" == "$pkg_dir" ]]; then
        continue
      fi

      pkg::plan_dir "$provider_dir"
      continue
    fi

    if pkg::pacman_can_resolve "$raw"; then
      continue
    fi

    echo "error: unresolved dependency for $pkg_label: $raw" >&2
    return 1
  done < <(pkg::metadata_deps "$pkg_dir")
}

pkg::plan_dir() {
  local pkg_dir="$1"
  local key

  pkg::validate_dir "$pkg_dir" || return

  key="$pkg_dir"

  case "${PKG_STATE[$key]-}" in
    done) return 0 ;;
    visiting)
      echo "error: dependency cycle detected at package: ${pkg_dir##*/}" >&2
      return 1
      ;;
  esac

  PKG_STATE["$key"]="visiting"

  if pkg::all_outputs_in_repo "$pkg_dir"; then
    PKG_STATE["$key"]="done"
    return 0
  fi

  pkg::plan_deps "$pkg_dir" "$key"
  PKG_PLAN+=("$pkg_dir")
  PKG_STATE["$key"]="done"
}

pkg::plan_selected() {
  local packages_dir="$1"
  shift
  local entry pkg_dir

  pkg::index_packages "$packages_dir"

  for entry in "$@"; do
    if [[ -d "$entry" || ( "$entry" != */* && -d "$packages_dir/$entry" ) ]]; then
      pkg_dir="$(pkg::resolve_dir "$entry" "$packages_dir")"
    else
      pkg_dir="${PKG_PROVIDER_DIR[$entry]-}"
      [[ -n "$pkg_dir" ]] || {
        echo "error: no local package provides: $entry" >&2
        return 1
      }
    fi

    pkg::plan_dir "$pkg_dir"
  done
}

pkg::print_plan() {
  local pkg_dir

  for pkg_dir in "${PKG_PLAN[@]}"; do
    printf '%s\t%s\n' "${pkg_dir##*/}" "$pkg_dir"
  done
}

pkg::build_plan() {
  local pkg_dir

  if declare -F chroot::enable_repo >/dev/null 2>&1; then
    chroot::enable_repo
  fi

  for pkg_dir in "${PKG_PLAN[@]}"; do
    pkg::build_dir "$pkg_dir"
    pkg::verify_outputs "$pkg_dir"
    pkg::publish_outputs "$pkg_dir"

    if declare -F chroot::enable_repo >/dev/null 2>&1; then
      chroot::enable_repo
    fi
  done
}

pkg::build_selected() {
  local packages_dir="$1"
  shift

  pkg::plan_selected "$packages_dir" "$@"
  pkg::build_plan
}
