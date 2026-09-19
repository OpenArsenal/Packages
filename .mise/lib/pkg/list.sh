# shellcheck shell=bash

pkg::ensure_file() {
  local packages_file="$1"
  if [[ ! -f "$packages_file" ]]; then
    mkdir -p "$(dirname "$packages_file")"
    : >"$packages_file"
    echo "Created empty packages file: $packages_file" >&2
  fi
}

# shellcheck disable=SC2034
pkg::load_requested() {
  local packages_file="$1"
  local outvar_name="$2"
  local -n outvar="$outvar_name"
  pkg::ensure_file "$packages_file"
  mapfile -t outvar < <(
    sed -e 's/\r$//' \
        -e 's/#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' "$packages_file" | awk 'NF'
  )
}
