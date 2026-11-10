#!/usr/bin/env bats
# onepassword package-specific Bats regression suite.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

@test "1Password updater preserves recipes after failed verification" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/pkg"
  cat >"$tmp/bin/wget" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -q && "$2" == -O ]] || exit 12
[[ "$4" != *"op_linux_${FAIL_WGET:-unlikely}_"* ]] || exit 42
printf 'fake zip data for %s' "$4" >"$3"
MOCK
  cat >"$tmp/bin/unzip" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -p && -f "$2" ]] || exit 12
[[ "$2" != *"op_linux_${FAIL_UNZIP:-unlikely}_"* ]] || exit 43
case "$3" in
  op) printf binary ;;
  op.sig) printf signature ;;
  *) exit 44 ;;
esac
MOCK
  cat >"$tmp/bin/gpgv" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -q && -s "$2" && -s "$3" ]] || exit 12
[[ "${FAIL_SIG:-0}" != 1 ]] || exit 45
MOCK
  chmod +x "$tmp/bin/"*
  cat >"$tmp/pkg/PKGBUILD" <<'RECIPE'
pkgname=1password-cli-bin
pkgver=2.42.0
pkgrel=1
sha256sums_x86_64=('old')
sha256sums_i686=('old')
sha256sums_arm=('old')
sha256sums_armv6h=('old')
sha256sums_aarch64=('old')
RECIPE
  printf precious >"$tmp/pkg/operations-notes.txt"
  printf precious2 >"$tmp/pkg/op-cache.txt"
  cp "$tmp/pkg/PKGBUILD" "$tmp/initial"

  for failure in wget unzip sig; do
    if (
      cd "$tmp/pkg"
      export PATH="$tmp/bin:$PATH" PKGVER=2.43.0
      case "$failure" in
        wget) export FAIL_WGET=arm ;;
        unzip) export FAIL_UNZIP=amd64 ;;
        sig) export FAIL_SIG=1 ;;
      esac
      bash "$root/packages/1password-cli-bin/package-update.sh" >"$tmp/log" 2>&1
    ); then
      fail "updater succeeded after $failure failure"
    fi
    cmp -s "$tmp/initial" "$tmp/pkg/PKGBUILD" || fail "updater changed recipe after $failure failure"
    [[ "$(cat "$tmp/pkg/operations-notes.txt")" == precious && "$(cat "$tmp/pkg/op-cache.txt")" == precious2 ]] || fail 'updater deleted unrelated files'
  done

  (
    cd "$tmp/pkg"
    PATH="$tmp/bin:$PATH" PKGVER=2.43.0 bash "$root/packages/1password-cli-bin/package-update.sh"
  ) || fail 'successful updater run failed'
  grep -qx 'pkgver=2.43.0' "$tmp/pkg/PKGBUILD" || fail 'pkgver not updated'
  for arch in x86_64 i686 arm armv6h aarch64; do
    grep -Eq "^sha256sums_$arch=\('[0-9a-f]{64}'\)$" "$tmp/pkg/PKGBUILD" || fail "checksum not updated: $arch"
  done
  [[ "$(cat "$tmp/pkg/operations-notes.txt")" == precious && "$(cat "$tmp/pkg/op-cache.txt")" == precious2 ]] || fail 'updater deleted unrelated files on success'
  echo 'PASS onepassword_update (failures preserve files; success updates checksums)'
  )
}

@test "1Password signature check preserves GPG arguments when srcdir contains spaces" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/package builds/src"
  export EXPECTED_SRCDIR="$tmp/package builds/src"
  export GPG_CAPTURE="$tmp/gpg-arguments" PATH="$tmp/bin:$PATH"
  printf 'program\n' >"$EXPECTED_SRCDIR/op"
  printf 'signature\n' >"$EXPECTED_SRCDIR/op.sig"

  cat >"$tmp/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" -eq 3 && "$1" == --verify ]] || exit 41
[[ "$2" == "$EXPECTED_SRCDIR/op.sig" && "$3" == "$EXPECTED_SRCDIR/op" ]] || exit 42
[[ -f "$2" && -f "$3" ]] || exit 43
printf '%s\n' "$@" >"$GPG_CAPTURE"
MOCK
  chmod +x "$tmp/bin/gpg"

  # Run the actual PKGBUILD check() function; no keys or external GPG
  # service are needed because the mock asserts the exact argument boundary.
  source "$root/packages/1password-cli-bin/PKGBUILD"
  srcdir="$EXPECTED_SRCDIR"
  SKIPPGPCHECK=0
  check || fail 'signature verification rejected a source path containing spaces'
  [[ -f "$GPG_CAPTURE" ]] || fail 'GPG was not called'
  local -a arguments=()
  mapfile -t arguments <"$GPG_CAPTURE"
  [[ "\${#arguments[@]}" -eq 3 &&
     "\${arguments[0]}" == --verify &&
     "\${arguments[1]}" == "$srcdir/op.sig" &&
     "\${arguments[2]}" == "$srcdir/op" ]] ||
    fail 'GPG did not receive exactly the signature and binary paths'

  rm -f -- "$GPG_CAPTURE"
  SKIPPGPCHECK=1
  check || fail 'SKIPPGPCHECK stopped bypassing signature verification'
  [[ ! -e "$GPG_CAPTURE" ]] || fail 'GPG ran even though signature verification was skipped'
  )
}
