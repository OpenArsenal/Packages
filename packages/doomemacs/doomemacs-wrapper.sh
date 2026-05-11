#!/usr/bin/env sh
set -eu

if [ -z "${HOME:-}" ]; then
  printf '%s\n' 'doom: HOME is not set; cannot resolve default XDG paths.' >&2
  exit 1
fi

xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
xdg_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
xdg_state_home="${XDG_STATE_HOME:-$HOME/.local/state}"

export EMACSDIR="${EMACSDIR:-/usr/share/doom-emacs}"
export DOOMDIR="${DOOMDIR:-$xdg_config_home/doom}"
export DOOMLOCALDIR="${DOOMLOCALDIR:-$xdg_data_home/doom-emacs/local}"
export DOOMPROFILELOADFILE="${DOOMPROFILELOADFILE:-$xdg_state_home/doom-emacs/profiles-load.el}"

case "${1:-}" in
  upgrade|up)
    cat >&2 <<'MESSAGE'
doom upgrade is disabled for the Arch doomemacs package.

This Doom installation is owned by pacman:

  /usr/share/doom-emacs

Upgrade Doom through pacman/AUR tooling instead, then run:

  doom sync
MESSAGE
    exit 1
    ;;
esac

exec "$EMACSDIR/bin/doom" "$@"