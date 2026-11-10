# shellcheck shell=bash

repo::update_add_args() {
  local include_new="$1"
  local prevent_downgrade="$2"
  local include_sigs="$3"
  local outvar_name="$4"
  local -n outvar="$outvar_name"

  outvar=()
  [[ "$include_new" == "true" ]] && outvar+=(--new)
  [[ "$prevent_downgrade" == "true" ]] && outvar+=(--prevent-downgrade)
  [[ "$include_sigs" == "true" ]] && outvar+=(--include-sigs)
  return 0
}

repo::match_package_archives() {
  local repo_dir="$1"
  local pkg_filter="$2"
  local pkg_version="${3:-}"
  local repo_dir_abs

  repo_dir_abs="$(cd "$repo_dir" && pwd -P)" || return 1

  (
    cd "$repo_dir_abs" || exit 1
    shopt -s nullglob

    local -a pkgs=()
    local pkg pkg_meta pkg_name pkg_ver
    local exact_name=false

    if [[ -n "$pkg_filter" ]]; then
      if [[ "$pkg_filter" == *".pkg.tar."* ]] \
        || [[ "$pkg_filter" == ./* ]] \
        || [[ "$pkg_filter" == */* ]] \
        || [[ "$pkg_filter" == *"*"* ]] \
        || [[ "$pkg_filter" == *"?"* ]] \
        || [[ "$pkg_filter" == *"["* ]]; then
        mapfile -t pkgs < <(compgen -G "$pkg_filter" || true)
      else
        # Narrow exact-name lookups before inspecting package metadata. The
        # metadata check below still rejects names that merely share a prefix.
        pkgs=( ./"${pkg_filter}"-*.pkg.tar.* )
        exact_name=true
      fi
    else
      pkgs=( ./*.pkg.tar.* )
    fi

    shopt -u nullglob

    for pkg in "${pkgs[@]}"; do
      [[ "$pkg" == *.sig ]] && continue
      [[ -f "$pkg" ]] || continue

      if [[ "$exact_name" == "true" ]]; then
        pkg_meta="$(pacman -Qp -- "$pkg" 2>/dev/null)" || {
          echo "error: unable to inspect matching archive: $pkg" >&2
          return 1
        }
        if [[ ! "$pkg_meta" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)$ ]]; then
          echo "error: invalid metadata for matching archive: $pkg" >&2
          return 1
        fi
        pkg_name="${BASH_REMATCH[1]}"
        pkg_ver="${BASH_REMATCH[2]}"

        [[ "$pkg_name" == "$pkg_filter" ]] || continue
        [[ -z "$pkg_version" || "$pkg_ver" == "$pkg_version" ]] || continue
      fi

      if [[ "$pkg" = /* ]]; then
        printf '%s\n' "$pkg"
      else
        printf '%s/%s\n' "$repo_dir_abs" "${pkg#./}"
      fi
    done | sort -uV
  )
}

repo::select_newest_archives() {
  local outvar_name="$1"
  shift
  local -n outvar="$outvar_name"
  outvar=()

  declare -A newest_file=()
  declare -A newest_ver=()

  local pkg pkg_meta pkg_name pkg_ver

  for pkg in "$@"; do
    if ! pkg_meta="$(pacman -Qp -- "$pkg" 2>/dev/null)"; then
      echo "error: unable to read package metadata: $pkg" >&2
      return 1
    fi

    if [[ ! "$pkg_meta" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)$ ]]; then
      echo "error: invalid package metadata for: $pkg" >&2
      return 1
    fi
    pkg_name="${BASH_REMATCH[1]}"
    pkg_ver="${BASH_REMATCH[2]}"

    if [[ -z "${newest_ver[$pkg_name]+x}" ]]; then
      newest_ver["$pkg_name"]="$pkg_ver"
      newest_file["$pkg_name"]="$pkg"
      continue
    fi

    local cmp
    cmp="$(vercmp "$pkg_ver" "${newest_ver[$pkg_name]}")" || {
      echo "error: failed to compare versions for $pkg_name" >&2
      return 1
    }

    case "$cmp" in
      1)
        newest_ver["$pkg_name"]="$pkg_ver"
        newest_file["$pkg_name"]="$pkg"
        ;;
      0|-1) ;;
      *)
        echo "error: invalid version comparison result for $pkg_name" >&2
        return 1
        ;;
    esac
  done

  [[ "${#newest_file[@]}" -gt 0 ]] || {
    outvar=()
    return 1
  }

  local -a pkg_names=()
  mapfile -t pkg_names < <(
    printf '%s\n' "${!newest_file[@]}" | sort
  )

  outvar=()
  for pkg_name in "${pkg_names[@]}"; do
    outvar+=("${newest_file[$pkg_name]}")
  done
}

repo::add_archives() {
  local repo_db="$1"
  local include_new="$2"
  local prevent_downgrade="$3"
  local include_sigs="$4"
  shift 4

  (( $# > 0 )) || {
    echo "error: no package archives supplied to repo-add" >&2
    return 1
  }

  local repo_add_help
  local -a args=()
  repo_add_help="$(repo-add --help 2>&1 || true)"
  [[ "$repo_add_help" == *"--wait-for-lock"* ]] && args+=(--wait-for-lock)

  local -a update_args=()
  repo::update_add_args \
    "$include_new" \
    "$prevent_downgrade" \
    "$include_sigs" \
    update_args
  args+=("${update_args[@]}")

  repo-add "${args[@]}" "$repo_db" "$@" || return

  if declare -F repo::index_reset >/dev/null 2>&1; then
    repo::index_reset
  fi
}

repo::update_db() {
  local repo_dir="$1"
  local repo_db="$2"
  local pkg_filter="$3"
  local include_new="$4"
  local prevent_downgrade="$5"
  local include_sigs="$6"
  local dry_run="${7:-false}"

  # A process substitution hides the producer's exit status. Capture its
  # output first so a partial/failed archive scan can never reach repo-add.
  local listing
  listing="$(repo::match_package_archives "$repo_dir" "$pkg_filter")" || {
    echo "error: unable to enumerate package archives in $repo_dir" >&2
    return 1
  }
  [[ -n "$listing" ]] || {
    echo "No matching package archives found in $repo_dir for: ${pkg_filter:-<all>}" >&2
    return 1
  }

  local -a candidates=()
  mapfile -t candidates <<<"$listing"

  local -a selected=()
  if ! repo::select_newest_archives selected "${candidates[@]}"; then
    echo "No readable package archives found in $repo_dir for: ${pkg_filter:-<all>}" >&2
    return 1
  fi

  # repo-add only records an archive's filename in the database; it does
  # not copy the file to the directory served by the repository. Validate
  # every selected archive *before* any publication (or dry-run output).
  # Check both the supplied path's directory and the symlink target:
  # an outside alias pointing *into* REPO_DIR is also not downloadable under
  # its advertised filename, even though realpath(1) resolves inside.
  local repo_dir_real archive archive_real archive_parent_real
  repo_dir_real="$(cd -- "$repo_dir" && pwd -P)" || {
    echo "error: unable to resolve repository directory: $repo_dir" >&2
    return 1
  }
  for archive in "${selected[@]}"; do
    archive_real="$(realpath -e -- "$archive")" || {
      echo "error: selected archive does not exist: $archive" >&2
      return 1
    }
    archive_parent_real="$(realpath -e -- "$(dirname -- "$archive")")" || {
      echo "error: unable to resolve selected archive's parent directory: $archive" >&2
      return 1
    }
    if [[ ! -f "$archive_real" || "$archive_parent_real" != "$repo_dir_real" ||
          "${archive_real%/*}" != "$repo_dir_real" ]]; then
      echo "error: selected archive is not a regular file inside REPO_DIR: $archive" >&2
      echo "       copy the archive into $repo_dir_real before running repo:update" >&2
      return 1
    fi
  done

  if [[ "$dry_run" == "true" ]]; then
    printf '%s\n' "${selected[@]}"
    return 0
  fi

  repo::add_archives \
    "$repo_db" \
    "$include_new" \
    "$prevent_downgrade" \
    "$include_sigs" \
    "${selected[@]}"
}

repo::refresh_sync_db() {
  local repo_name="$1"
  local db_path sync_dir

  db_path="$(pacman-conf DBPath)" || {
    echo "error: unable to read pacman DBPath" >&2
    return 1
  }
  # Never invalidate an unexpected /sync directory if pacman-conf returns
  # empty, relative, or root-level paths.
  [[ -n "$db_path" && "$db_path" == /* ]] || {
    echo "error: invalid pacman DBPath: $db_path" >&2
    return 1
  }
  db_path="$(realpath -m -- "$db_path")" || return 1
  [[ "$db_path" != "/" ]] || {
    echo "error: refusing root-level pacman DBPath" >&2
    return 1
  }
  sync_dir="$db_path/sync"

  task::run_root rm -f \
    "${sync_dir}/${repo_name}.db"* \
    "${sync_dir}/${repo_name}.files"* || {
      echo "error: failed to invalidate pacman sync database for: $repo_name" >&2
      return 1
    }

  task::run_root pacman -Sy --noconfirm || {
    echo "error: failed to refresh pacman sync database for: $repo_name" >&2
    return 1
  }
}
