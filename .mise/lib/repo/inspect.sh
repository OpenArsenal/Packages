# shellcheck shell=bash

declare -Ag REPO_PACKAGE_VERSION=()
declare -Ag REPO_PROVIDE_VERSION=()
declare -Ag REPO_PROVIDE_PRESENT=()
declare -g REPO_INDEX_DIR=""

repo::index_reset() {
  REPO_PACKAGE_VERSION=()
  REPO_PROVIDE_VERSION=()
  REPO_PROVIDE_PRESENT=()
  REPO_INDEX_DIR=""
}

repo::version_satisfies() {
  local actual="$1"
  local op="$2"
  local wanted="$3"

  [[ -z "$op" || -z "$wanted" ]] && return 0

  local cmp
  cmp="$(vercmp "$actual" "$wanted")"

  case "$op" in
    '=')  (( cmp == 0 )) ;;
    '>')  (( cmp > 0 )) ;;
    '>=') (( cmp >= 0 )) ;;
    '<')  (( cmp < 0 )) ;;
    '<=') (( cmp <= 0 )) ;;
    *) return 1 ;;
  esac
}

repo::remember_max_version() {
  local map_name="$1"
  local key="$2"
  local version="$3"
  local -n map="$map_name"

  if [[ -z "${map[$key]+x}" ]] || (( $(vercmp "$version" "${map[$key]}") > 0 )); then
    map["$key"]="$version"
  fi
}

repo::index_build() {
  local repo_dir="$1"
  local archive meta pkg_name pkg_ver raw provide_name provide_op provide_ver

  repo::index_reset

  while IFS= read -r -d '' archive; do
    meta="$(bsdtar -xOf "$archive" .PKGINFO 2>/dev/null)" || {
      echo "warning: unable to inspect package archive: $archive" >&2
      continue
    }

    pkg_name="$(awk -F ' = ' '$1=="pkgname" {print $2; exit}' <<<"$meta")"
    pkg_ver="$(awk -F ' = ' '$1=="pkgver" {print $2; exit}' <<<"$meta")"

    if [[ -n "$pkg_name" && -n "$pkg_ver" ]]; then
      repo::remember_max_version REPO_PACKAGE_VERSION "$pkg_name" "$pkg_ver"
    fi

    while IFS= read -r raw; do
      [[ -n "$raw" ]] || continue

      provide_name=""
      provide_op=""
      provide_ver=""
      spec::parse "$raw" provide_name provide_op provide_ver
      [[ -n "$provide_name" ]] || continue

      REPO_PROVIDE_PRESENT["$provide_name"]=1
      if [[ -n "$provide_ver" ]]; then
        repo::remember_max_version REPO_PROVIDE_VERSION "$provide_name" "$provide_ver"
      fi
    done < <(awk -F ' = ' '$1=="provides" {print $2}' <<<"$meta")
  done < <(
    find "$repo_dir" -maxdepth 1 -type f       -name '*.pkg.tar.*' ! -name '*.sig' -print0 2>/dev/null
  )

  REPO_INDEX_DIR="$repo_dir"
}

repo::ensure_index() {
  local repo_dir="$1"
  [[ "$REPO_INDEX_DIR" == "$repo_dir" ]] || repo::index_build "$repo_dir"
}

repo::is_dep_satisfied() {
  local repo_dir="$1"
  local dep="$2"
  local op="$3"
  local ver="$4"

  repo::ensure_index "$repo_dir"

  if [[ -n "${REPO_PACKAGE_VERSION[$dep]+x}" ]]     && repo::version_satisfies "${REPO_PACKAGE_VERSION[$dep]}" "$op" "$ver"; then
    return 0
  fi

  [[ -n "${REPO_PROVIDE_PRESENT[$dep]+x}" ]] || return 1

  if [[ -z "$op" || -z "$ver" ]]; then
    return 0
  fi

  [[ -n "${REPO_PROVIDE_VERSION[$dep]+x}" ]]     && repo::version_satisfies "${REPO_PROVIDE_VERSION[$dep]}" "$op" "$ver"
}

repo::has_built_pkg() {
  repo::is_dep_satisfied "$1" "$2" "" ""
}

repo::db_packages() {
  local repo_db="$1"
  local entry

  [[ -e "$repo_db" ]] || return 0

  while IFS= read -r entry; do
    [[ "$entry" == */desc ]] || continue

    bsdtar -xOf "$repo_db" "$entry" 2>/dev/null |
      awk '$0=="%NAME%" { getline; print; exit }'
  done < <(bsdtar -tf "$repo_db" 2>/dev/null)
}
