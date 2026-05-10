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

is_wayland() {
  [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == 'wayland' ]]
}

is_nvidia() {
  [[ -e /proc/driver/nvidia/version || -d /sys/module/nvidia || -d /sys/module/nvidia_drm ]]
}

set_env_default() {
  local assignment="$1"
  local name value

  [[ "$assignment" == *=* ]] || return 1
  name="${assignment%%=*}"
  value="${assignment#*=}"

  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

  if [[ -z "${!name+x}" ]]; then
    export "${name}=${value}"
  fi
}

gg_flags=()
gg_args=()
args=()

read_flags "$XDG_CONFIG_HOME/gg-flags.conf" gg_flags

for flag in "${gg_flags[@]}"; do
  case "$flag" in
    *=*)
      set_env_default "$flag" || true
      ;;
    *)
      gg_args+=("$flag")
      ;;
  esac
done

if is_wayland; then
  set_env_default 'WEBKIT_DISABLE_DMABUF_RENDERER=1'
  set_env_default 'WEBKIT_DISABLE_COMPOSITING_MODE=1'

  if is_nvidia; then
    set_env_default '__NV_DISABLE_EXPLICIT_SYNC=1'
  fi
fi

for arg in "$@"; do
  args+=("$arg")
done

exec @GG_EXEC@ "${gg_args[@]}" "${args[@]}"
