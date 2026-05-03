#!/usr/bin/env bash

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}

read_flags() {
  local file="$1"
  local -n out="$2"
  local line

  out=()
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] && out+=("$line")
  done <"$file"
}

logseq_flags=()
platform_flags=()
args=()

read_flags "$XDG_CONFIG_HOME/logseq-flags.conf" logseq_flags

for arg in "$@"; do
  case "$arg" in
    --wayland)
      platform_flags+=("--ozone-platform=wayland")
      ;;
    --x11|--xwayland)
      platform_flags+=("--ozone-platform=x11")
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done

exec @LOGSEQ_EXEC@ "${logseq_flags[@]}" "${platform_flags[@]}" "${args[@]}"
