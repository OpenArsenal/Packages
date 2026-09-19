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
