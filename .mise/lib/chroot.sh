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
    task::run_root tee -a "$pacman_conf" >/dev/null
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

  task::run_root mkdir -p "$CHROOT_DIR"

  local mount_opts
  mount_opts="$(findmnt --noheadings --output OPTIONS --target "$CHROOT_DIR" 2>/dev/null || true)"
  if [[ ",$mount_opts," == *,nosuid,* ]]; then
    echo "error: chroot filesystem is mounted nosuid: $CHROOT_DIR" >&2
    echo "       set CHROOT_BASE to a filesystem that permits setuid binaries" >&2
    return 1
  fi

  local resolved_conf
  resolved_conf="$(mktemp)"
  trap 'rm -f "$resolved_conf"' RETURN

  if [[ -n "${CHROOT_PACMAN_CONF:-}" ]]; then
    [[ -f "$CHROOT_PACMAN_CONF" ]] || {
      echo "error: pacman config not found: $CHROOT_PACMAN_CONF" >&2
      return 1
    }

    pacman-conf --config "$CHROOT_PACMAN_CONF" >"$resolved_conf"
  else
    pacman-conf >"$resolved_conf"
  fi

  local -a packages=(base-devel git archlinux-keyring)
  if pacman -Si cachyos-keyring >/dev/null 2>&1; then
    packages+=(cachyos-keyring)
  fi

  task::run_root mkarchroot -C "$resolved_conf" "$root" "${packages[@]}"
  task::run_root install -m 0644 "$resolved_conf" "$root/etc/pacman.conf"
}

chroot::update() {
  task::require_env CHROOT_DIR

  local root
  root="$(chroot::root)"

  [[ -f "$root/etc/pacman.conf" ]] || {
    echo "error: chroot is not provisioned: $root" >&2
    return 1
  }

  task::run_root arch-nspawn "$root" pacman -Syu --noconfirm
}

chroot::destroy() {
  task::require_env CHROOT_DIR

  case "$CHROOT_DIR" in
    "" | "/" | ".")
      echo "error: refusing to delete CHROOT_DIR=$CHROOT_DIR" >&2
      return 1
      ;;
  esac

  task::run_root rm -rf -- "$CHROOT_DIR"
}
