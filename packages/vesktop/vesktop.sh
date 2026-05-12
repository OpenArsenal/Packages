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

set -f
exec /usr/lib/vesktop/vesktop $VESKTOP_USER_FLAGS "$@"
