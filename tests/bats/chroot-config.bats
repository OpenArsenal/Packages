#!/usr/bin/env bats
# File-backed integration coverage for clean-chroot repository configuration.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Chroot repository setup repairs conflicting stanzas and preserves unrelated configuration" {
  (
  local tmp pacman_conf
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_NAME=openarsenal REPO_DIR="$tmp/repo"
  export REPO_DB="$REPO_DIR/openarsenal.db.tar.zst"
  export REPO_SIG_LEVEL="Optional TrustAll" CHROOT_DIR="$tmp/chroot"
  mkdir -p "$REPO_DIR" "$CHROOT_DIR/root/etc"
  touch "$REPO_DB"
  pacman_conf="$CHROOT_DIR/root/etc/pacman.conf"

  source "$root/.mise/lib/task.sh"
  source "$root/.mise/lib/repo/config.sh"
  source "$root/.mise/lib/chroot.sh"
  # Exercise the real file rewrite without requiring root or Arch tooling.
  task::run_root() { "$@"; }

  cat >"$pacman_conf" <<EOF
[options]
HoldPkg = pacman

[openarsenal]
SigLevel = Optional TrustAll
Server = file://$REPO_DIR

[core]
Server = https://mirror.example/core

[openarsenal]
SigLevel = Optional TrustAll
Server = file:///stale/repo
EOF

  chroot::enable_repo || fail 'duplicate repository sections could not be repaired'
  [[ "$(grep -c '^\[openarsenal\]$' "$pacman_conf")" -eq 1 ]] ||
    fail 'duplicate repository stanza remained in chroot'
  grep -Fq "Server = file://$REPO_DIR" "$pacman_conf" ||
    fail 'expected local repository server was lost'
  ! grep -Fq 'file:///stale/repo' "$pacman_conf" ||
    fail 'stale repository server was retained'
  grep -Fq '[core]' "$pacman_conf" ||
    fail 'unrelated repository configuration was removed'
  grep -Fq 'HoldPkg = pacman' "$pacman_conf" ||
    fail 'unrelated pacman options were removed'

  # A second server inside an otherwise correct stanza must also be repaired.
  printf 'Server = file:///wrong/extra\n' >>"$pacman_conf"
  chroot::enable_repo || fail 'conflicting server could not be repaired'
  [[ "$(grep -c '^\[openarsenal\]$' "$pacman_conf")" -eq 1 ]] ||
    fail 'repository stanza duplicated while repairing extra server'
  ! grep -Fq 'file:///wrong/extra' "$pacman_conf" ||
    fail 'conflicting extra server was retained'

  cp "$pacman_conf" "$tmp/expected"
  chroot::enable_repo || fail 'valid repository configuration was rejected'
  cmp -s "$pacman_conf" "$tmp/expected" ||
    fail 'valid chroot repository configuration changed on reapplication'
  )
}
