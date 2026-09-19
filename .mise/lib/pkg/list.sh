# shellcheck shell=bash

pkg::load_requested() {
  local packages_file="$1"
  local outvar_name="$2"
  local -n outvar="$outvar_name"

  [[ -f "$packages_file" ]] || {
    outvar=()
    return 0
  }

  mapfile -t outvar < <(
    sed -e 's/\r$//' \
        -e 's/#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' "$packages_file" |
      awk 'NF'
  )
}

pkg::pacman_info_value() {
  local mode="$1"
  local target="$2"
  local field="$3"

  LC_ALL=C pacman "-${mode}i" "$target" 2>/dev/null |
    awk -F ':' -v field="$field" '
      {
        key=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

        if (key == field) {
          sub(/^[^:]*:[[:space:]]*/, "", $0)
          print
          exit
        }
      }
    '
}

pkg::installed_selected() {
  local packages_dir="$1"
  local repo_name="$2"
  local outvar_name="$3"
  local -n outvar="$outvar_name"

  LC_ALL=C pacman -Sl "$repo_name" >/dev/null 2>&1 || {
    echo "error: pacman repository unavailable: $repo_name" >&2
    echo "       configure and refresh the repository before selecting installed packages" >&2
    return 1
  }

  declare -A installed=()
  local name pkg_dir output installed_packager repo_packager

  while IFS= read -r name; do
    [[ -n "$name" ]] && installed["$name"]=1
  done < <(pacman -Qq)

  outvar=()
  shopt -s nullglob

  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    while IFS= read -r output; do
      [[ -n "$output" ]] || continue
      [[ -n "${installed[$output]+x}" ]] || continue

      repo_packager="$(pkg::pacman_info_value S "$repo_name/$output" Packager)"
      [[ -n "$repo_packager" ]] || continue

      installed_packager="$(pkg::pacman_info_value Q "$output" Packager)"
      [[ -n "$installed_packager" ]] || continue

      if [[ "$installed_packager" == "$repo_packager" ]]; then
        outvar+=("${pkg_dir##*/}")
        break
      fi
    done < <(pkg::metadata_outputs "$pkg_dir")
  done

  shopt -u nullglob
}

pkg::write_selected() {
  local packages_file="$1"
  shift

  local tmp
  tmp="$(mktemp "${packages_file}.XXXXXX")"

  if (( $# > 0 )); then
    printf '%s\n' "$@" >"$tmp"
  else
    : >"$tmp"
  fi

  mv "$tmp" "$packages_file"
}
