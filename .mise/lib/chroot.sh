# shellcheck shell=bash

chroot::root() {
  printf '%s/root\n' "${CHROOT_DIR:?CHROOT_DIR not set}"
}

chroot::repo_matches() {
  local pacman_conf="$1"
  local repo_name="$2"
  local repo_dir="$3"
  local sig_level="$4"

  awk     -v section="[$repo_name]"     -v expected_sig="SigLevel = $sig_level"     -v expected_server="Server = file://$repo_dir" '
      function finish_section() {
        if (in_section && sig_ok && server_ok) {
          matched = 1
        }
      }

      $0 == section {
        finish_section()
        in_section = 1
        sig_ok = 0
        server_ok = 0
        next
      }

      in_section && /^\[[^]]+\][[:space:]]*$/ {
        finish_section()
        in_section = 0
      }

      in_section && $0 == expected_sig {
        sig_ok = 1
      }

      in_section && $0 == expected_server {
        server_ok = 1
      }

      END {
        finish_section()
        exit !matched
      }
    ' "$pacman_conf"
}

chroot::enable_repo() {
  task::require_env CHROOT_DIR REPO_NAME REPO_DIR REPO_DB REPO_SIG_LEVEL

  [[ -e "$REPO_DB" ]] || return 0

  local root pacman_conf tmp
  root="$(chroot::root)"
  pacman_conf="$root/etc/pacman.conf"

  [[ -f "$pacman_conf" ]] || return 0

  if chroot::repo_matches "$pacman_conf" "$REPO_NAME" "$REPO_DIR" "$REPO_SIG_LEVEL"; then
    return 0
  fi

  tmp="$(mktemp)"

  if ! awk -v section="[$REPO_NAME]" '
    $0 == section {
      skip = 1
      next
    }

    skip && /^\[[^]]+\][[:space:]]*$/ {
      skip = 0
    }

    !skip {
      print
    }
  ' "$pacman_conf" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  printf '\n' >>"$tmp"
  repo::pacman_stanza "$REPO_NAME" "$REPO_DIR" "$REPO_SIG_LEVEL" >>"$tmp"

  if ! task::run_root install -m 0644 "$tmp" "$pacman_conf"; then
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp"
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

  if [[ -n "${CHROOT_PACMAN_CONF:-}" ]]; then
    [[ -f "$CHROOT_PACMAN_CONF" ]] || {
      echo "error: pacman config not found: $CHROOT_PACMAN_CONF" >&2
      rm -f "$resolved_conf"
      return 1
    }

    if ! pacman-conf --config "$CHROOT_PACMAN_CONF" >"$resolved_conf"; then
      rm -f "$resolved_conf"
      return 1
    fi
  elif ! pacman-conf >"$resolved_conf"; then
    rm -f "$resolved_conf"
    return 1
  fi

  local -a packages=(base-devel git archlinux-keyring)
  if pacman -Si cachyos-keyring >/dev/null 2>&1; then
    packages+=(cachyos-keyring)
  fi

  if ! task::run_root mkarchroot -C "$resolved_conf" "$root" "${packages[@]}"; then
    rm -f "$resolved_conf"
    return 1
  fi

  if ! task::run_root install -m 0644 "$resolved_conf" "$root/etc/pacman.conf"; then
    rm -f "$resolved_conf"
    return 1
  fi

  rm -f "$resolved_conf"
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
