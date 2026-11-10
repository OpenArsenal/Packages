#!/usr/bin/env bats
# Exercise the Edge updater with mocked XML metadata and build tools.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Edge updater refuses incomplete metadata without modifying PKGBUILD" {
  (
  local tmp missing
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/home/.local/share/chroot"
  export TEST_TMP="$tmp" HOME="$tmp/home" PATH="$tmp/bin:$PATH"
  export TEST_FILELISTS='repodata/test-filelists.xml.gz'
  export TEST_VER='146.0.3856.85'
  export TEST_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

  cat >"$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  pull) exit 0 ;;
  diff) exit 1 ;;
  add|commit) exit 0 ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '<metadata>test</metadata>\n'
MOCK
  cat >"$tmp/bin/gzip" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -dc ]] || exit 2
cat
MOCK
  cat >"$tmp/bin/xmllint" <<'MOCK'
#!/usr/bin/env bash
# Consume XML before returning a fixture value. Otherwise producers can
# receive SIGPIPE, and pipefail makes this test nondeterministic.
cat >/dev/null || exit 2
case "$2" in
  *'@href'*) printf '%s' "$TEST_FILELISTS" ;;
  *'@ver'*) printf '%s' "$TEST_VER" ;;
  *'@pkgid'*) printf '%s' "$TEST_HASH" ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/makechrootpkg" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/build-ran"
MOCK
  cat >"$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --printsrcinfo ]] || exit 2
printf 'pkgbase = microsoft-edge-stable-bin\n'
MOCK
  chmod +x "$tmp/bin/"*

  printf '_channel=stable\npkgver=146.0.3856.84\npkgrel=2\nsha256sums=('\''bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\''\n)\n' >"$tmp/PKGBUILD"
  cp "$tmp/PKGBUILD" "$tmp/original"

  for missing in filelists version checksum invalid-version invalid-checksum; do
    TEST_FILELISTS='repodata/test-filelists.xml.gz'
    TEST_VER='146.0.3856.85'
    TEST_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    case "$missing" in
      filelists) TEST_FILELISTS='' ;;
      version) TEST_VER='' ;;
      checksum) TEST_HASH='' ;;
      invalid-version) TEST_VER='not-a-version' ;;
      invalid-checksum) TEST_HASH='invalid' ;;
    esac
    rm -f "$tmp/build-ran" "$tmp/.SRCINFO"
    if (cd "$tmp" && bash "$root/packages/microsoft-edge-stable-bin/update_version.sh") >"$tmp/log" 2>&1; then
      fail "Edge updater accepted $missing upstream metadata"
    fi
    cmp -s "$tmp/PKGBUILD" "$tmp/original" ||
      fail "Edge updater changed the recipe after $missing upstream metadata"
    case "$missing" in
      filelists) diagnostic='missing or invalid Edge filelists' ;;
      version|invalid-version) diagnostic='missing or invalid Edge version' ;;
      checksum|invalid-checksum) diagnostic='missing or invalid Edge SHA-256' ;;
    esac
    grep -Fq "$diagnostic" "$tmp/log" ||
      fail "Edge updater did not report the expected error for $missing metadata"
    [[ ! -e "$tmp/build-ran" && ! -e "$tmp/.SRCINFO" ]] ||
      fail "Edge updater started a build after $missing upstream metadata"
  done

  TEST_FILELISTS='repodata/test-filelists.xml.gz'
  TEST_VER='146.0.3856.85'
  TEST_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  (cd "$tmp" && bash "$root/packages/microsoft-edge-stable-bin/update_version.sh") >"$tmp/log" 2>&1 ||
    fail "Edge updater rejected valid metadata: $(cat "$tmp/log")"
  grep -Fxq 'pkgver=146.0.3856.85' "$tmp/PKGBUILD" ||
    fail 'valid metadata did not update the version'
  grep -Fq "$TEST_HASH" "$tmp/PKGBUILD" ||
    fail 'valid metadata did not update the checksum'
  [[ -e "$tmp/build-ran" && -f "$tmp/.SRCINFO" ]] ||
    fail 'valid metadata did not complete the update workflow'
  )
}
