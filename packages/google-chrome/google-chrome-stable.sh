#!/usr/bin/env bash
# OpenArsenal launcher: one argument per non-comment line.
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
flags=()
if [[ -r "$config_dir/chrome-flags.conf" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    flags+=("$line")
  done < "$config_dir/chrome-flags.conf"
fi
exec /opt/google/chrome/google-chrome "${flags[@]}" "$@"
