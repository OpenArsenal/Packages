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
}

repo::match_package_archives() {
  local repo_dir="$1"
  local pkg_filter="$2"
  local repo_dir_abs

  repo_dir_abs="$(cd "$repo_dir" && pwd -P)" || return 1

  (
    cd "$repo_dir_abs" || exit 1
    shopt -s nullglob

    local -a pkgs=()
    local pkg

    if [[ -n "$pkg_filter" ]]; then
      if [[ "$pkg_filter" == *".pkg.tar."* ]] \
        || [[ "$pkg_filter" == ./* ]] \
        || [[ "$pkg_filter" == */* ]] \
        || [[ "$pkg_filter" == *"*"* ]] \
        || [[ "$pkg_filter" == *"?"* ]] \
        || [[ "$pkg_filter" == *"["* ]]; then
        mapfile -t pkgs < <(compgen -G "$pkg_filter" || true)
      else
        pkgs=(
          ./"$pkg_filter"-*.pkg.tar.*
          ./"$pkg_filter".pkg.tar.*
          ./"$pkg_filter"*.pkg.tar.*
        )
      fi
    else
      pkgs=( ./*.pkg.tar.* )
    fi

    shopt -u nullglob

    for pkg in "${pkgs[@]}"; do
      [[ "$pkg" == *.sig ]] && continue
      [[ -f "$pkg" ]] || continue

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

  declare -A newest_file=()
  declare -A newest_ver=()

  local pkg pkg_meta pkg_name pkg_ver

  for pkg in "$@"; do
    if ! pkg_meta="$(pacman -Qp -- "$pkg" 2>/dev/null)"; then
      echo "warning: unable to read package metadata; skipping: $pkg" >&2
      continue
    fi

    pkg_name="${pkg_meta%% *}"
    pkg_ver="${pkg_meta#* }"

    if [[ -z "${newest_ver[$pkg_name]+x}" ]] \
      || (( $(vercmp "$pkg_ver" "${newest_ver[$pkg_name]}") > 0 )); then
      newest_ver["$pkg_name"]="$pkg_ver"
      newest_file["$pkg_name"]="$pkg"
    fi
  done

  if [[ "${#newest_file[@]}" -eq 0 ]]; then
    outvar=()
    return 1
  fi

  local -a pkg_names=()
  mapfile -t pkg_names < <(printf '%s\n' "${!newest_file[@]}" | sort)

  outvar=()
  for pkg_name in "${pkg_names[@]}"; do
    outvar+=("${newest_file[$pkg_name]}")
  done
}

repo::update_db() {
  local repo_dir="$1"
  local repo_db="$2"
  local pkg_filter="$3"
  local include_new="$4"
  local prevent_downgrade="$5"
  local include_sigs="$6"

  local -a args=()
  repo::update_add_args \
    "$include_new" \
    "$prevent_downgrade" \
    "$include_sigs" \
    args

  local -a candidates=()
  if ! mapfile -t candidates < <(repo::match_package_archives "$repo_dir" "$pkg_filter") \
    || [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "No matching package archives found in $repo_dir for: ${pkg_filter:-<all>}" >&2
    return 1
  fi

  local -a selected=()
  if ! repo::select_newest_archives selected "${candidates[@]}"; then
    echo "No readable package archives found in $repo_dir for: ${pkg_filter:-<all>}" >&2
    return 1
  fi

  repo-add "${args[@]}" "$repo_db" "${selected[@]}"
}

repo::refresh_sync_db() {
  local repo_name="$1"
  local sync_dir="/var/lib/pacman/sync"

  sudo rm -f "${sync_dir}/${repo_name}.db"* "${sync_dir}/${repo_name}.files"*
  sudo pacman -Sy
}

repo::reindex() {
  repo::update_db "$REPO_DIR" "$REPO_DB" "" false false false
}
