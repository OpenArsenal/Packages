# shellcheck shell=bash

repo::has_pkgdir() {
  local packages_dir="$1"
  local name="$2"
  [[ -d "${packages_dir}/${name}" ]]
}

repo::has_built_pkg() {
  local repo_dir="$1"
  local name="$2"
  compgen -G "${repo_dir}/${name}-*.pkg.tar.*" >/dev/null 2>&1
}

repo::has_built_pkg_exact_ver() {
  local repo_dir="$1"
  local name="$2"
  local ver="$3"
  compgen -G "${repo_dir}/${name}-${ver}-*.pkg.tar.*" >/dev/null 2>&1
}

repo::is_dep_satisfied() {
  local repo_dir="$1"
  local dep="$2"
  local op="$3"
  local ver="$4"
  if [[ "$op" == "=" && -n "$ver" ]]; then
    if repo::has_built_pkg_exact_ver "$repo_dir" "$dep" "$ver"; then
      echo "dep already in repo (exact): $dep=$ver" >&2
      return 0
    fi
    return 1
  fi
  if repo::has_built_pkg "$repo_dir" "$dep"; then
    echo "dep already in repo: $dep" >&2
    return 0
  fi
  return 1
}
