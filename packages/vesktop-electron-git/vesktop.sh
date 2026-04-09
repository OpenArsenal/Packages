#!/bin/sh

if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  config_home=$XDG_CONFIG_HOME
else
  config_home=$HOME/.config
fi

read_flags() {
  flags_file=$1

  [ -f "$flags_file" ] || return 0

  sed \
    -e 's/[[:space:]]*$//' \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' \
    "$flags_file"
}

VESKTOP_USER_FLAGS=$(read_flags "$config_home/vesktop-flags.conf")

export ELECTRON_IS_DEV=0
export ELECTRON_FORCE_IS_PACKAGED=true
export NODE_ENV=production

set -f

if [ "$(id -u)" -eq 0 ] && [ -z "${ELECTRON_RUN_AS_NODE:-}" ]; then
  # shellcheck disable=SC2086
  exec /usr/bin/electron /usr/lib/vesktop/app.asar --no-sandbox $VESKTOP_USER_FLAGS "$@"
else
  # shellcheck disable=SC2086
  exec /usr/bin/electron /usr/lib/vesktop/app.asar $VESKTOP_USER_FLAGS "$@"
fi