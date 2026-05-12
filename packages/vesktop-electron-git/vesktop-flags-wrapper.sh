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

electron_flags=()
platform_flags=()
vesktop_flags=()
args=()

read_flags "$XDG_CONFIG_HOME/electron-flags.conf" electron_flags
read_flags "$XDG_CONFIG_HOME/vesktop-flags.conf" vesktop_flags

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

export ELECTRON_IS_DEV=0
export ELECTRON_FORCE_IS_PACKAGED=true
export NODE_ENV=production

exec @ELECTRON_CMD@ "${electron_flags[@]}" "${platform_flags[@]}" @VESKTOP_APP@ "${vesktop_flags[@]}" "${args[@]}"
