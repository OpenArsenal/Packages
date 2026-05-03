#!/usr/bin/env bash

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
_APP_EXEC="@AFFINE_EXEC@"
_APPDIR="${_APP_EXEC%/*}"

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

affine_flags=()
platform_flags=()
args=()

read_flags "$XDG_CONFIG_HOME/affine-flags.conf" affine_flags

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

if [[ "${EUID}" -eq 0 && -z "${ELECTRON_RUN_AS_NODE:-}" ]]; then
  platform_flags+=("--no-sandbox")
fi

export ELECTRON_OZONE_PLATFORM_HINT=auto
export NODE_ENV=production

cd "${_APPDIR}" || { echo "Failed to change directory to ${_APPDIR}"; exit 1; }
exec "${_APP_EXEC}" "${platform_flags[@]}" "${affine_flags[@]}" "${args[@]}"
