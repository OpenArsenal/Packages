#!/usr/bin/env bash
set -euo pipefail

pkgname='singularityapp'

export SNAP="/opt/singularityapp"
export SNAP_NAME="singularityapp"
export SNAP_INSTANCE_NAME="singularityapp"
export SNAP_VERSION="12.4.1"
export SNAP_REVISION="141"
export SNAP_ARCH="amd64"

export SNAP_USER_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/${pkgname}"
export SNAP_USER_COMMON="$SNAP_USER_DATA"
export SNAP_DATA="${XDG_STATE_HOME:-$HOME/.local/state}/${pkgname}"
export SNAP_COMMON="$SNAP_DATA"

export PATH="$SNAP/usr/bin:$SNAP/bin:$PATH"
export XDG_DATA_DIRS="$SNAP/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export LD_LIBRARY_PATH="$SNAP/lib:$SNAP/lib/x86_64-linux-gnu:$SNAP/usr/lib:$SNAP/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

mkdir -p "$SNAP_USER_DATA" "$SNAP_USER_COMMON" "$SNAP_DATA" "$SNAP_COMMON"
printf '%s\n' "$SNAP_REVISION" >"$SNAP_USER_DATA/.last_revision"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

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

singularityapp_flags=()
platform_flags=()
args=()

read_flags "$XDG_CONFIG_HOME/singularityapp-flags.conf" singularityapp_flags

for arg in "$@"; do
  case "$arg" in
  --wayland)
    platform_flags+=(
      "--enable-features=UseOzonePlatform,WaylandWindowDecorations"
      "--ozone-platform=wayland"
    )
    ;;
  --x11 | --xwayland)
    platform_flags+=("--ozone-platform=x11")
    ;;
  *)
    args+=("$arg")
    ;;
  esac
done

cd "$SNAP"

exec "$SNAP/command.sh" \
  "${singularityapp_flags[@]}" \
  "${platform_flags[@]}" \
  "${args[@]}"
