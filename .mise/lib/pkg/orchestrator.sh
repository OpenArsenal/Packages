# shellcheck shell=bash

pkg::build_selected() {
  local -a requested=("$@")
  pkg::resolver_reset
  local entry
  for entry in "${requested[@]}"; do
    echo "==> processing: $(printf '%q' "$entry")" >&2
    if [[ "$entry" = /* ]]; then
      if ! pkg::validate_pkg_dir "$entry"; then
        continue
      fi
      pkg::build_pkgdir "$entry"
    else
      pkg::build_with_deps "$entry"
    fi
  done
  repo::reindex
}
