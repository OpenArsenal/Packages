# shellcheck shell=bash

pkg::load_requested() {
  local packages_file="$1"
  local outvar_name="$2"
  local -n outvar="$outvar_name"
  local entries

  [[ -f "$packages_file" ]] || {
    outvar=()
    return 0
  }

  # A process substitution would hide a failed sed/awk and could accept a
  # truncated package selection. Collect and check before modifying outvar.
  entries="$(
    set -o pipefail
    sed -e 's/\r$//' \
        -e 's/#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' "$packages_file" |
      awk 'NF'
  )" || {
    echo "error: unable to read package selection: $packages_file" >&2
    return 1
  }

  outvar=()
  [[ -z "$entries" ]] || mapfile -t outvar <<<"$entries"
}

pkg::pacman_info_value() {
  local mode="$1"
  local target="$2"
  local field="$3"
  local info

  info="$(LC_ALL=C pacman "-${mode}i" "$target" 2>/dev/null)" || return 1

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
  ' <<<"$info"
}

pkg::installed_selected() {
  local packages_dir="$1"
  local repo_name="$2"
  local outvar_name="$3"
  local -n outvar="$outvar_name"

  [[ -d "$packages_dir" && -r "$packages_dir" && -x "$packages_dir" ]] || {
    echo "error: package source directory missing or unreadable: $packages_dir" >&2
    return 1
  }

  LC_ALL=C pacman -Sl "$repo_name" >/dev/null 2>&1 || {
    echo "error: pacman repository unavailable: $repo_name" >&2
    echo "       configure and refresh the repository before selecting installed packages" >&2
    return 1
  }

  declare -A installed=()
  declare -A output_dirs=()
  declare -A output_count=()
  declare -A repo_installed=()
  declare -A selected_dirs=()

  local name pkg_dir output outputs candidate candidates exact_dir
  local installed_packager repo_packager
  local covered installed_names

  installed_names="$(pacman -Qq)" || {
    echo "error: unable to list installed packages" >&2
    return 1
  }

  while IFS= read -r name; do
    [[ -n "$name" ]] && installed["$name"]=1
  done <<<"$installed_names"

  shopt -s nullglob

  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue
    pkg::cache_srcinfo "$pkg_dir" || { shopt -u nullglob; return 1; }
    outputs="$(pkg::metadata_outputs "$pkg_dir")" || {
      echo "error: unable to read package outputs: $pkg_dir" >&2
      shopt -u nullglob
      return 1
    }
    if [[ -z "$outputs" ]]; then
      echo "error: no package outputs declared: $pkg_dir" >&2
      shopt -u nullglob
      return 1
    fi

    while IFS= read -r output; do
      [[ -n "$output" ]] || continue
      output_dirs["$output"]+=" $pkg_dir"
      (( output_count["$output"] += 1 ))
    done <<<"$outputs"
  done

  for output in "${!output_dirs[@]}"; do
    [[ -n "${installed[$output]+x}" ]] || continue

    installed_packager="$(pkg::pacman_info_value Q "$output" Packager)" || {
      echo "error: unable to read installed package metadata: $output" >&2
      return 1
    }
    [[ -n "$installed_packager" ]] || {
      echo "error: missing packager in installed package metadata: $output" >&2
      return 1
    }

    # A local recipe may not have a published entry in this repository.
    repo_packager="$(pkg::pacman_info_value S "$repo_name/$output" Packager)" || continue
    [[ -n "$repo_packager" ]] || continue
    [[ "$installed_packager" == "$repo_packager" ]] || continue

    repo_installed["$output"]=1
  done

  # Unique outputs identify their source directory unambiguously.
  for output in "${!repo_installed[@]}"; do
    (( output_count["$output"] == 1 )) || continue
    candidate="${output_dirs[$output]# }"
    selected_dirs["$candidate"]=1
  done

  # Shared outputs are already covered when a more specific installed output
  # selected one of their source directories. Otherwise prefer an exact
  # repository directory-name match, and warn rather than guessing.
  for output in "${!repo_installed[@]}"; do
    (( output_count["$output"] > 1 )) || continue

    candidates="${output_dirs[$output]}"
    covered=false

    for candidate in $candidates; do
      if [[ -n "${selected_dirs[$candidate]+x}" ]]; then
        covered=true
        break
      fi
    done

    [[ "$covered" == "true" ]] && continue

    exact_dir="$packages_dir/$output"
    if [[ "$candidates" == *" $exact_dir"* && -f "$exact_dir/PKGBUILD" ]]; then
      selected_dirs["$exact_dir"]=1
      continue
    fi

    echo "warning: ambiguous installed package '$output'; skipping source selection" >&2
  done

  outvar=()
  for pkg_dir in "$packages_dir"/*; do
    [[ -n "${selected_dirs[$pkg_dir]+x}" ]] || continue
    outvar+=("${pkg_dir##*/}")
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
