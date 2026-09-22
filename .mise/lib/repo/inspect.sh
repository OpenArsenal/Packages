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

repo::db_records() {
  local repo_db="$1"
  local -a entries=()

  [[ -e "$repo_db" ]] || return 0

  if ! mapfile -t entries < <(
    bsdtar -tf "$repo_db" 2>/dev/null | awk '/\/desc$/'
  ); then
    return 1
  fi

  (( ${#entries[@]} > 0 )) || return 0

  # Extract all desc members in one bsdtar invocation. Emit compact records:
  # P <name> <version> for packages and R <provide> for provides entries.
  bsdtar -xOf "$repo_db" "${entries[@]}" 2>/dev/null |
    awk '
      function flush_package() {
        if (name != "" && version != "") {
          printf "P\t%s\t%s\n", name, version
        }
        name = ""
        version = ""
      }

      $0 == "%NAME%" {
        flush_package()
        mode = "name"
        next
      }

      $0 == "%VERSION%" {
        mode = "version"
        next
      }

      $0 == "%PROVIDES%" {
        mode = "provides"
        next
      }

      /^%.*%$/ {
        mode = ""
        next
      }

      NF == 0 {
        if (mode == "provides") {
          mode = ""
        }
        next
      }

      mode == "name" {
        name = $0
        mode = ""
        next
      }

      mode == "version" {
        version = $0
        mode = ""
        next
      }

      mode == "provides" {
        printf "R\t%s\n", $0
      }

      END {
        flush_package()
      }
    '
}

repo::index_build() {
  local repo_dir="$1"
  local repo_db="${REPO_DB:-}"
  local records kind first second
  local raw provide_name provide_op provide_ver

  repo::index_reset

  if [[ -z "$repo_db" || ! -e "$repo_db" ]]; then
    REPO_INDEX_DIR="$repo_dir"
    return 0
  fi

  if ! records="$(repo::db_records "$repo_db")"; then
    echo "error: unable to inspect repository database: $repo_db" >&2
    return 1
  fi

  while IFS=$'\t' read -r kind first second; do
    case "$kind" in
      P)
        [[ -n "$first" && -n "$second" ]] &&
          repo::remember_max_version REPO_PACKAGE_VERSION "$first" "$second"
        ;;
      R)
        raw="$first"
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
        ;;
    esac
  done <<<"$records"

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

  if [[ -n "${REPO_PACKAGE_VERSION[$dep]+x}" ]] \
    && repo::version_satisfies "${REPO_PACKAGE_VERSION[$dep]}" "$op" "$ver"; then
    return 0
  fi

  [[ -n "${REPO_PROVIDE_PRESENT[$dep]+x}" ]] || return 1

  if [[ -z "$op" || -z "$ver" ]]; then
    return 0
  fi

  [[ -n "${REPO_PROVIDE_VERSION[$dep]+x}" ]] \
    && repo::version_satisfies "${REPO_PROVIDE_VERSION[$dep]}" "$op" "$ver"
}

repo::has_built_pkg() {
  repo::is_dep_satisfied "$1" "$2" "" ""
}

repo::db_packages() {
  local repo_db="$1"
  local records kind name version

  [[ -e "$repo_db" ]] || return 0

  records="$(repo::db_records "$repo_db")" || return 1

  while IFS=$'\t' read -r kind name version; do
    [[ "$kind" == "P" && -n "$name" ]] && printf '%s\n' "$name"
  done <<<"$records"
}
