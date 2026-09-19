# shellcheck shell=bash

declare -Ag PKG_VISITED

pkg::resolver_reset() {
  PKG_VISITED=()
}

pkg::build_with_deps() {
  local pkg_name="$1"
  local pkg_dir="${PACKAGES_DIR}/${pkg_name}"
  echo "[repo:build-selected] --> build_with_deps: $(printf '%q' "$pkg_name") dir=$(printf '%q' "$pkg_dir")" >&2
  if [[ -n "${PKG_VISITED[$pkg_name]-}" ]]; then
    echo "[repo:build-selected] already visited: $pkg_name" >&2
    return 0
  fi
  PKG_VISITED["$pkg_name"]=1
  if [[ ! -d "$pkg_dir" ]]; then
    echo "warning: package directory not found; skipping: $pkg_dir (package: $pkg_name)" >&2
    return 0
  fi
  if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
    echo "warning: missing PKGBUILD; skipping: $pkg_dir (package: $pkg_name)" >&2
    return 0
  fi
  if pkg::all_outputs_in_repo "$pkg_dir"; then
    echo "Already in repo; skipping build: $pkg_name" >&2
    return 0
  fi
  pkg::ensure_deps_built "$pkg_name" "$pkg_dir"
  pkg::build_pkgdir "$pkg_dir"
}

pkg::ensure_deps_built() {
  local pkg_name="$1"
  local pkg_dir="$2"
  local -a dep_rows=()
  if ! mapfile -t dep_rows < <(pkg::list_local_deps "$pkg_dir"); then
    echo "warning: failed to list deps for $pkg_name" >&2
  fi
  echo "[repo:build-selected] deps list for $pkg_name:" >&2
  if [[ "${#dep_rows[@]}" -eq 0 ]]; then
    echo "[repo:build-selected]   (no deps)" >&2
    return 0
  fi
  local sep=$'\x1f'
  local row dep_spec dep op ver
  local candidate normalized
  local satisfied
  for row in "${dep_rows[@]}"; do
    dep_spec=""
    dep=""
    op=""
    ver=""
    IFS="$sep" read -r dep_spec dep op ver <<<"$row"
    printf '[repo:build-selected]   - %q\n' "$dep_spec" >&2
    [[ -z "$dep" ]] && continue
    satisfied=false
    candidate="$dep"
    if repo::is_dep_satisfied "$REPO_DIR" "$candidate" "$op" "$ver"; then
      satisfied=true
    elif repo::has_pkgdir "$PACKAGES_DIR" "$candidate"; then
      pkg::build_with_deps "$candidate"
      satisfied=true
    elif pkg::pacman_has "$candidate"; then
      satisfied=true
    else
      normalized="$(pkg::normalize_dep_name "$dep")"
      if [[ "$normalized" != "$dep" ]]; then
        candidate="$normalized"
        if repo::is_dep_satisfied "$REPO_DIR" "$candidate" "$op" "$ver"; then
          satisfied=true
        elif repo::has_pkgdir "$PACKAGES_DIR" "$candidate"; then
          pkg::build_with_deps "$candidate"
          satisfied=true
        elif pkg::pacman_has "$candidate"; then
          satisfied=true
        fi
      fi
    fi
    if [[ "$satisfied" == true ]]; then
      continue
    fi
    echo "warning: dependency not found for $pkg_name: $dep (not in ${PACKAGES_DIR}, not already built in repo, and pacman -Si failed)" >&2
  done
}

pkg::normalize_dep_name() {
  local dep="$1"
  case "$dep" in
    udev) printf '%s\n' systemd ;;
    *)    printf '%s\n' "$dep" ;;
  esac
}

pkg::all_outputs_in_repo() {
  local pkg_dir="$1"
  local out
  local found_any=false
  while IFS= read -r out; do
    [[ -z "$out" ]] && continue
    found_any=true
    if ! repo::has_built_pkg "$REPO_DIR" "$out"; then
      return 1
    fi
  done < <(pkg::pkgbuild_list_pkgnames "$pkg_dir")
  [[ "$found_any" == true ]]
}
