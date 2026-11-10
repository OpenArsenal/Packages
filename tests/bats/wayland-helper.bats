#!/usr/bin/env bats
# Integration coverage for split-package Wayland helper lifecycle metadata.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "All five Wayland variants package their lifecycle hooks and executable helpers" {
  (
  local tmp srcdir pkgdir variant target hook action script
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  srcdir="$root/packages/1password-wayland"
  source "$srcdir/PKGBUILD"

  for variant in 1password-wayland electron-fiddle-wayland element-desktop-wayland rambox-pro-bin-wayland signal-desktop-wayland; do
    pkgname="$variant"
    pkgdir="$tmp/package-$variant"
    "package_$variant" || fail "could not stage $variant"

    [[ "$install" == "$variant.install" && -f "$srcdir/$install" ]] ||
      fail "$variant does not declare an existing lifecycle script"

    for action in patch unpatch; do
      script="$pkgdir/usr/share/libalpm/scripts/$variant-$action"
      [[ -x "$script" ]] || fail "$variant did not package its executable $action helper"
      ! grep -Fq '{{' "$script" || fail "$variant has unresolved $action template placeholders"
    done

    hook="$pkgdir/usr/share/libalpm/hooks/$variant.hook"
    [[ -f "$hook" ]] || fail "$variant did not package its upgrade hook"
    grep -Fxq "Exec = /usr/share/libalpm/scripts/$variant-patch" "$hook" ||
      fail "$variant upgrade hook references a missing patch executable"
    target="${variant%-wayland}"
    grep -Fxq "Target = $target" "$hook" ||
      fail "$variant upgrade hook does not target its original application"
    ! grep -Fq '{{' "$hook" || fail "$variant hook has unresolved placeholders"
  done
  )
}

@test "All five Wayland install scripts call patch on install/upgrade and unpatch on removal" {
  (
  local tmp srcdir variant action
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  srcdir="$root/packages/1password-wayland"
  mkdir -p "$tmp/bin"

  for variant in 1password-wayland electron-fiddle-wayland element-desktop-wayland rambox-pro-bin-wayland signal-desktop-wayland; do
    for action in patch unpatch; do
      cat >"$tmp/bin/$variant-$action" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${0##*-}" >>"$WAYLAND_EVENTS"
MOCK
      chmod +x "$tmp/bin/$variant-$action"
    done

    # Redirect absolute invocations to fixture helpers; do not patch host files.
    sed "s#/usr/share/libalpm/scripts/#$tmp/bin/#g" "$srcdir/$variant.install" >"$tmp/lifecycle.install"
    source "$tmp/lifecycle.install"
    WAYLAND_EVENTS="$tmp/events"
    export WAYLAND_EVENTS
    : >"$WAYLAND_EVENTS"

    post_install '0.1.6-2' >"$tmp/log" 2>&1 ||
      fail "$variant post_install failed"
    post_upgrade '0.1.6-2' '0.1.6-1' >>"$tmp/log" 2>&1 ||
      fail "$variant post_upgrade failed"
    pre_remove '0.1.6-2' >>"$tmp/log" 2>&1 ||
      fail "$variant pre_remove failed"

    [[ "$(cat "$WAYLAND_EVENTS")" == $'patch\npatch\nunpatch' ]] ||
      fail "$variant has an incomplete lifecycle: $(cat "$WAYLAND_EVENTS")"
  done
  )
}

@test "Local source verifier rejects mismatched checksums" {
  (
  local tmp checksum
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/demo"
  printf 'original file\n' >"$tmp/demo/script.sh"
  printf 'post_install() { :; }\n' >"$tmp/demo/demo.install"
  checksum="$(sha512sum "$tmp/demo/script.sh")" || fail 'could not hash fixture'
  checksum="${checksum%% *}"
  printf 'pkgbase = demo\n\tinstall = demo.install\n\tsource = script.sh\n\tsha512sums = %s\n' "$checksum" >"$tmp/demo/.SRCINFO"

  python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1 ||
    fail "valid local checksum was rejected: $(cat "$tmp/log")"

  printf 'changed file\n' >"$tmp/demo/script.sh"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'stale local checksum was accepted'
  fi
  grep -Fq 'sha512sums mismatch for script.sh' "$tmp/log" ||
    fail 'stale local checksum did not identify its source file'

  printf 'original file\n' >"$tmp/demo/script.sh"
  rm -f "$tmp/demo/demo.install"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'missing package installation hook was accepted'
  fi
  grep -Fq 'missing install script: demo.install' "$tmp/log" ||
    fail 'missing installation hook did not identify the expected file'
  )
}

@test "Wayland patch never replaces the original launcher after backup failures" {
  (
  local tmp target backup launcher script failure
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/app"
  target="$tmp/app/executable"
  backup="$tmp/backups/executable"
  launcher="$tmp/launcher.sh"
  script="$tmp/patch.sh"

  printf 'original application executable\n' >"$target"
  cp "$target" "$tmp/expected"
  printf '#!/bin/bash\nexit 0\n' >"$launcher"
  chmod +x "$target" "$launcher"

  # Render the real shipped patch template for disposable paths only.
  sed -e "s#{{launcher}}#$launcher#g" \
      -e "s#{{target}}#$target#g" \
      -e "s#{{backup}}#$backup#g" \
    "$root/packages/1password-wayland/electron-wayland-patch.sh" >"$script"

  cat >"$tmp/bin/mkdir" <<'MOCK'
#!/usr/bin/env bash
printf 'mkdir\n' >>"$WAYLAND_BACKUP_LOG"
if [[ "$WAYLAND_FAIL_STEP" == mkdir ]]; then exit 91; fi
exec /usr/bin/mkdir "$@"
MOCK
  cat >"$tmp/bin/mv" <<'MOCK'
#!/usr/bin/env bash
printf 'mv\n' >>"$WAYLAND_BACKUP_LOG"
if [[ "$WAYLAND_FAIL_STEP" == mv ]]; then exit 92; fi
exec /usr/bin/mv "$@"
MOCK
  cat >"$tmp/bin/ln" <<'MOCK'
#!/usr/bin/env bash
printf 'ln\n' >>"$WAYLAND_BACKUP_LOG"
exec /usr/bin/ln "$@"
MOCK
  chmod +x "$tmp/bin/"*

  for failure in mkdir mv; do
    : >"$tmp/calls"
    if PATH="$tmp/bin:$PATH" WAYLAND_FAIL_STEP="$failure" WAYLAND_BACKUP_LOG="$tmp/calls" \
        bash "$script" >"$tmp/output" 2>&1; then
      fail "Wayland patch succeeded after failed $failure"
    fi
    [[ -f "$target" && ! -L "$target" ]] ||
      fail "failed $failure replaced the original launcher"
    cmp -s "$target" "$tmp/expected" ||
      fail "failed $failure modified the original executable"
    [[ ! -e "$backup" ]] ||
      fail "failed $failure unexpectedly wrote a backup"
    if grep -Fxq ln "$tmp/calls"; then
      fail "failed $failure still invoked ln to replace the launcher"
    fi
  done

  : >"$tmp/calls"
  PATH="$tmp/bin:$PATH" WAYLAND_FAIL_STEP=none WAYLAND_BACKUP_LOG="$tmp/calls" \
    bash "$script" >"$tmp/output" 2>&1 ||
    fail "Wayland patch failed with a writable backup: $(cat "$tmp/output")"
  [[ -L "$target" && "$(readlink "$target")" == "$launcher" ]] ||
    fail 'successful backup did not install the Wayland launcher symlink'
  cmp -s "$backup" "$tmp/expected" ||
    fail 'successful patch did not preserve the original executable in the backup'
  )
}

@test "Wayland unpatch preserves foreign symlinks and stops if restoring backup fails" {
  (
  local tmp target backup launcher foreign script
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/app" "$tmp/demo-wayland/original" "$tmp/bin"
  target="$tmp/app/executable"
  backup="$tmp/demo-wayland/original/executable"
  launcher="$tmp/wayland-launcher"
  foreign="$tmp/other-application"
  script="$tmp/unpatch.sh"

  printf 'original executable\n' >"$backup"
  cp "$backup" "$tmp/expected"
  printf '#!/bin/bash\nexit 0\n' >"$launcher"
  printf 'custom executable\n' >"$foreign"

  # Render the real unpatch script against disposable fixture paths.
  sed -e "s#{{executable}}#$backup#g" \
      -e 's#{{pkgname}}#demo-wayland#g' \
      -e "s#{{target}}#$target#g" \
      -e "s#{{launcher}}#$launcher#g" \
    "$root/packages/1password-wayland/electron-wayland-unpatch.sh" >"$script"

  ln -s "$foreign" "$target"
  if bash "$script" >"$tmp/log" 2>&1; then
    fail 'Wayland unpatch accepted a symlink belonging to another application'
  fi
  [[ -L "$target" && "$(readlink "$target")" == "$foreign" ]] ||
    fail 'Wayland unpatch changed an unrelated symlink'
  cmp -s "$backup" "$tmp/expected" ||
    fail 'Wayland unpatch changed the backup after rejecting an unrelated symlink'

  rm "$target"
  ln -s "$launcher" "$target"

  cat >"$tmp/bin/mv" <<'MOCK'
#!/usr/bin/env bash
exit 87
MOCK
  cat >"$tmp/bin/rmdir" <<'MOCK'
#!/usr/bin/env bash
touch "$WAYLAND_RMDIR_MARKER"
MOCK
  chmod +x "$tmp/bin/"*

  if WAYLAND_RMDIR_MARKER="$tmp/rmdir-called" PATH="$tmp/bin:$PATH" bash "$script" >"$tmp/log" 2>&1; then
    fail 'Wayland unpatch ignored failed backup restoration'
  fi
  [[ -L "$target" && "$(readlink "$target")" == "$launcher" ]] ||
    fail 'Wayland unpatch replaced its symlink despite failed restoration'
  cmp -s "$backup" "$tmp/expected" ||
    fail 'Wayland unpatch lost the backup after a failed move'
  [[ ! -e "$tmp/rmdir-called" ]] ||
    fail 'Wayland unpatch attempted directory removal after failed restoration'

  bash "$script" >"$tmp/log" 2>&1 ||
    fail "Wayland unpatch could not restore a valid backup: $(cat "$tmp/log")"
  [[ -f "$target" && ! -L "$target" ]] ||
    fail 'successful unpatch did not restore the original executable'
  cmp -s "$target" "$tmp/expected" ||
    fail 'successful unpatch changed the original executable'

  # The direct-executable variant also restores only helper-owned links.
  printf 'direct executable\n' >"$tmp/direct-executable"
  sed -e "s#{{executable}}#$tmp/direct-executable#g" \
      -e 's#{{pkgname}}#demo-wayland#g' \
      -e "s#{{target}}#$target#g" \
      -e "s#{{launcher}}#$launcher#g" \
    "$root/packages/1password-wayland/electron-wayland-unpatch.sh" >"$script"
  rm "$target"
  ln -s "$launcher" "$target"
  bash "$script" >"$tmp/log" 2>&1 ||
    fail "Wayland unpatch could not restore a direct executable: $(cat "$tmp/log")"
  [[ -L "$target" && "$(readlink "$target")" == "$tmp/direct-executable" ]] ||
    fail 'successful direct-executable unpatch restored the wrong target'
  )
}
