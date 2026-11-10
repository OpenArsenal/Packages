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
  checksum="$(sha512sum "$tmp/demo/script.sh")" || fail 'could not hash fixture'
  checksum="${checksum%% *}"
  printf 'pkgbase = demo\n\tsource = script.sh\n\tsha512sums = %s\n' "$checksum" >"$tmp/demo/.SRCINFO"

  python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1 ||
    fail "valid local checksum was rejected: $(cat "$tmp/log")"

  printf 'changed file\n' >"$tmp/demo/script.sh"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'stale local checksum was accepted'
  fi
  grep -Fq 'sha512sums mismatch for script.sh' "$tmp/log" ||
    fail 'stale local checksum did not identify its source file'
  )
}
