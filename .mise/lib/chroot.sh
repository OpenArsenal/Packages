# shellcheck shell=bash

chroot::root() {
  printf '%s/root
' "${CHROOT_DIR:?CHROOT_DIR not set}"
}

chroot::enable_repo() {
  task::require_env CHROOT_DIR REPO_NAME REPO_DIR REPO_DB REPO_SIG_LEVEL

  [[ -e "$REPO_DB" ]] || return 0

  local root pacman_conf
  root="$(chroot::root)"
  pacman_conf="$root/etc/pacman.conf"

  [[ -f "$pacman_conf" ]] || return 0
  grep -qxF "[$REPO_NAME]" "$pacman_conf" && return 0

  repo::pacman_stanza "$REPO_NAME" "$REPO_DIR" "$REPO_SIG_LEVEL" |
    run0 tee -a "$pacman_conf" >/dev/null
}

chroot::create() {
  task::require_env CHROOT_DIR

  local root
  root="$(chroot::root)"

  if [[ -f "$root/etc/pacman.conf" ]]; then
    echo "Chroot already provisioned: $root"
    return 0
  fi

  if [[ -e "$root" ]]; then
    echo "error: chroot root exists but is not provisioned: $root" >&2
    return 1
  fi

  mkdir -p "$CHROOT_DIR"

  local -a args=()
  if [[ -n "${CHROOT_PACMAN_CONF:-}" ]]; then
    [[ -f "$CHROOT_PACMAN_CONF" ]] || {
      echo "error: pacman config not found: $CHROOT_PACMAN_CONF" >&2
      return 1
    }
    args+=(-C "$CHROOT_PACMAN_CONF")
  fi

  local -a packages=(base-devel git archlinux-keyring)
  if pacman -Si cachyos-keyring >/dev/null 2>&1; then
    packages+=(cachyos-keyring)
  fi

  run0 mkarchroot "${args[@]}" "$root" "${packages[@]}"
}

chroot::destroy() {
  task::require_env CHROOT_DIR

  case "$CHROOT_DIR" in
    "" | "/" | ".")
      echo "error: refusing to delete CHROOT_DIR=$CHROOT_DIR" >&2
      return 1
      ;;
  esac

  run0 rm -rf -- "$CHROOT_DIR"
}
