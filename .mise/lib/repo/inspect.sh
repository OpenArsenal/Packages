# shellcheck shell=bash

declare -Ag REPO_PACKAGE_VERSION=()
declare -Ag REPO_PROVIDE_VERSIONS=()
declare -Ag REPO_PROVIDE_PRESENT=()
# Each alias maps to "published package owner<TAB>provided version" records.
# Ownership lets build planning exclude obsolete aliases when an owner is replaced.
declare -Ag REPO_PROVIDE_OWNERS=()
declare -g REPO_INDEX_DIR=""

repo::index_reset() {
  REPO_PACKAGE_VERSION=()
  REPO_PROVIDE_VERSIONS=()
  REPO_PROVIDE_PRESENT=()
  REPO_PROVIDE_OWNERS=()
  REPO_INDEX_DIR=""
}

repo::version_satisfies() {
  local actual="$1"
  local op="$2"
  local wanted="$3"

  [[ -z "$op" || -z "$wanted" ]] && return 0

  local cmp
  cmp="$(vercmp "$actual" "$wanted")" || return 1
  case "$cmp" in
    -1|0|1) ;;
    *) return 1 ;;
  esac

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

  if [[ -n "${map[$key]+x}" ]]; then
    local cmp
    cmp="$(vercmp "$version" "${map[$key]}")" || return 1
    case "$cmp" in
      1) ;;
      -1|0) return 0 ;;
      *) return 1 ;;
    esac
  fi
  map["$key"]="$version"
}

repo::db_records() {
  local repo_db="$1"
  local -a entries=()

  [[ -e "$repo_db" ]] || return 0

  local listing contents records entry record
  local record_count=0
  listing="$(bsdtar -tf "$repo_db" 2>/dev/null)" || return 1
  # Keep member discovery inside this shell, without an unchecked producer.
  while IFS= read -r entry; do
    if [[ "$entry" == */desc ]]; then
      entries+=("$entry")
    fi
  done <<<"$listing"

  (( ${#entries[@]} > 0 )) || return 0

  # Extract all desc members in one bsdtar invocation. Emit compact records:
  # P <name> <version>, R <provide> <owning package>, and F <archive filename>.
  contents="$(bsdtar -xOf "$repo_db" "${entries[@]}" 2>/dev/null)" || return 1
  records="$(awk '
      function flush_package(    count, lines, i) {
        if (name != "" && version != "") {
          printf "P\t%s\t%s\n", name, version
          count = split(provided, lines, "\n")
          for (i = 1; i <= count; i++) {
            if (lines[i] != "") printf "R\t%s\t%s\n", lines[i], name
          }
        }
        name = ""
        version = ""
        provided = ""
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

      $0 == "%FILENAME%" {
        mode = "filename"
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

      mode == "filename" {
        printf "F\t%s\n", $0
        mode = ""
        next
      }

      mode == "provides" {
        provided = provided $0 "\n"
      }

      END {
        flush_package()
      }
    ' <<<"$contents")" || return 1

  # Reject malformed desc members before exposing a partial repository index.
  while IFS= read -r record; do
    if [[ "$record" == P* ]]; then
      (( record_count += 1 ))
    fi
  done <<<"$records"
  if (( record_count != ${#entries[@]} )); then
    echo "error: incomplete repository package metadata in: $repo_db" >&2
    return 1
  fi

  [[ -z "$records" ]] || printf '%s\n' "$records"
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
        if [[ -n "$first" && -n "$second" ]]; then
          if ! repo::remember_max_version REPO_PACKAGE_VERSION "$first" "$second"; then
            echo "error: unable to compare repository package versions: $first" >&2
            repo::index_reset
            return 1
          fi
        fi
        ;;
      R)
        raw="$first"
        [[ -n "$raw" ]] || continue
        [[ -n "$second" ]] || {
          echo "error: published provider has no owning package: $raw" >&2
          repo::index_reset
          return 1
        }

        provide_name=""
        provide_op=""
        provide_ver=""
        spec::parse "$raw" provide_name provide_op provide_ver
        [[ -n "$provide_name" ]] || continue

        REPO_PROVIDE_PRESENT["$provide_name"]=1
        REPO_PROVIDE_OWNERS["$provide_name"]+="$second"$'\t'"$provide_ver"$'\n'
        if [[ -n "$provide_ver" ]]; then
          REPO_PROVIDE_VERSIONS["$provide_name"]+="${provide_ver}"$'\n'
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

  repo::ensure_index "$repo_dir" || return 1

  if [[ -n "${REPO_PACKAGE_VERSION[$dep]+x}" ]] \
    && repo::version_satisfies "${REPO_PACKAGE_VERSION[$dep]}" "$op" "$ver"; then
    return 0
  fi

  [[ -n "${REPO_PROVIDE_PRESENT[$dep]+x}" ]] || return 1

  if [[ -z "$op" || -z "$ver" ]]; then
    return 0
  fi

  local provided
  while IFS= read -r provided; do
    if [[ -n "$provided" ]] && repo::version_satisfies "$provided" "$op" "$ver"; then
      return 0
    fi
  done <<< "${REPO_PROVIDE_VERSIONS[$dep]-}"
  return 1
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
  return 0
}
