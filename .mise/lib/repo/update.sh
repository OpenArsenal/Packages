# shellcheck shell=bash

repo::update_add_args() {
  local include_new="$1"
  local prevent_downgrade="$2"
  local include_sigs="$3"
  local outvar_name="$4"
  local -n outvar="$outvar_name"
  outvar=()
  if [[ "$include_new" == "true" ]]; then
    outvar+=(--new)
  fi
  if [[ "$prevent_downgrade" == "true" ]]; then
    outvar+=(--prevent-downgrade)
  fi
  if [[ "$include_sigs" == "true" ]]; then
    outvar+=(--include-sigs)
  fi
  return 0
}

repo::match_package_archives() {
  local repo_dir="$1"
  local pkg_filter="$2"
  (
    cd "$repo_dir" || exit 1
    shopt -s nullglob
    local -a pkgs=()
    if [[ -n "$pkg_filter" ]]; then
      if [[ "$pkg_filter" == *".pkg.tar."* ]] \
        || [[ "$pkg_filter" == ./* ]] \
        || [[ "$pkg_filter" == */* ]] \
        || [[ "$pkg_filter" == *"*"* ]] \
        || [[ "$pkg_filter" == *"?"* ]] \
        || [[ "$pkg_filter" == *"["* ]]; then
        pkgs=( "$pkg_filter" )
      else
        pkgs=(
          ./"$pkg_filter"-*.pkg.tar.zst
          ./"$pkg_filter".pkg.tar.zst
          ./"$pkg_filter"*.pkg.tar.zst
        )
      fi
    else
      pkgs=( ./*.pkg.tar.zst )
    fi
    shopt -u nullglob
    if [[ "${#pkgs[@]}" -eq 0 ]]; then
      exit 1
    fi
    printf '%s\n' "${pkgs[@]}" | sort -V
  )
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
  local -a pkgs=()
  if ! mapfile -t pkgs < <(repo::match_package_archives "$repo_dir" "$pkg_filter"); then
    echo "No matching package archives found in $repo_dir for: ${pkg_filter:-<all>}" >&2
    return 1
  fi
  (
    cd "$repo_dir" || exit 1
    local pkg
    for pkg in "${pkgs[@]}"; do
      repo-add "${args[@]}" "$repo_db" "$pkg"
    done
  )
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
