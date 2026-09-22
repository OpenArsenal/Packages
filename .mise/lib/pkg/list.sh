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

pkg::installed_selected() {
  local packages_dir="$1"
  local outvar_name="$2"
  local -n outvar="$outvar_name"

  declare -A installed=()
  local name pkg_dir output

  while IFS= read -r name; do
    [[ -n "$name" ]] && installed["$name"]=1
  done < <(pacman -Qq)

  outvar=()
  shopt -s nullglob

  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    while IFS= read -r output; do
      [[ -n "$output" ]] || continue

      if [[ -n "${installed[$output]+x}" ]]; then
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

  printf '%s\n' "$@" >"$tmp"
  mv "$tmp" "$packages_file"
}
