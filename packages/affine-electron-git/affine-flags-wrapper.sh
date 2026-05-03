#!/usr/bin/env bash

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
_APPDIR="/usr/lib/affine"

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
affine_flags=()
args=()

read_flags "$XDG_CONFIG_HOME/electron-flags.conf" electron_flags
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
  electron_flags+=("--no-sandbox")
fi

export PATH="${_APPDIR}:${PATH}"
export LD_LIBRARY_PATH="${_APPDIR}/swiftshader:${_APPDIR}/lib:${LD_LIBRARY_PATH}"
export ELECTRON_IS_DEV=0
export ELECTRON_FORCE_IS_PACKAGED=true
export ELECTRON_DISABLE_SECURITY_WARNINGS=true
export ELECTRON_OZONE_PLATFORM_HINT=auto
export NODE_ENV=production

cd "${_APPDIR}" || { echo "Failed to change directory to ${_APPDIR}"; exit 1; }
exec @ELECTRON_CMD@ "${electron_flags[@]}" "${platform_flags[@]}" @AFFINE_APP@ "${affine_flags[@]}" "${args[@]}"
