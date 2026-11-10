#!/usr/bin/env bats
# Chrome Stable/Canary updater contracts: real scripts, fake Gitiles responses.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

chrome_mock_curl() {
  mkdir -p "$1/bin"
  cat >"$1/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output="" url="" code=200
while (( $# )); do
  case "$1" in
    -o|-w)
      if [[ "$1" == -o ]]; then output="$2"; fi
      shift 2 ;;
    -sS|-L) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ -n "$output" && "$url" == *'/DEPS?format=TEXT' ]] || exit 90
printf '%s\n' "$url" >>"$CHROME_URL_LOG"

case "$CHROME_TEST_MODE" in
  transport) exit 56 ;;
  http403) code=403 ;;
  http429) code=429 ;;
  http500) code=500 ;;
  fallback)
    if [[ "$url" == *"/refs/tags/$CHROME_REQUESTED/DEPS?format=TEXT" ]]; then
      code=404
    fi
    ;;
esac

if [[ "$code" == 200 ]]; then
  case "$CHROME_TEST_MODE" in
    decode) printf 'not@@base64' >"$output" ;;
    no-ref) printf "  'something_else': 'none',\n" | base64 >"$output" ;;
    invalid-ref) printf "  'ffmpeg_revision': 'too-short',\n" | base64 >"$output" ;;
    *) printf "  'ffmpeg_revision': '%s',\n" "$CHROME_REF" | base64 >"$output" ;;
  esac
else
  printf 'upstream error\n' >"$output"
fi
printf '%s' "$code"
MOCK
  chmod +x "$1/bin/curl"
}

chrome_variant() {
  case "$1" in
    stable)
      script="$root/packages/google-chrome-ffmpeg/update-chrome-ref.sh"
      version=153.0.8010.52
      ;;
    canary)
      script="$root/packages/google-chrome-canary-ffmpeg/update-chrome-ref.sh"
      version=154.0.8024.0
      ;;
    *) fail "unknown variant: $1" ;;
  esac
}

chrome_recipe() {
  cat >"$tmp/PKGBUILD" <<RECIPE
pkgname=chrome-fixture
pkgver=1.2.3.4
pkgrel=3
_channel=$variant
# Chromium 1.2.3.4 third_party/ffmpeg revision.
_chromium_ffmpeg_ref=0000000000000000000000000000000000000000
sha512sums=('untouched-checksum')
unrelated='keep me'
RECIPE
}

chrome_update() {
  PATH="$tmp/bin:$PATH" CHROME_TEST_MODE="$1" CHROME_REF="$ref" \
    CHROME_REQUESTED="$version" CHROME_URL_LOG="$tmp/requests" \
    bash "$script" "$version" "$tmp/PKGBUILD" >"$tmp/output" 2>&1
}

@test "Chrome Stable and Canary updaters preserve recipes after failed metadata" {
  (
  local tmp variant mode script version ref
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  chrome_mock_curl "$tmp"
  ref=0123456789abcdef0123456789abcdef01234567

  for variant in stable canary; do
    chrome_variant "$variant"
    [[ -f "$script" ]] || fail "missing $variant Chrome updater"
    for mode in transport http403 http429 http500 decode no-ref invalid-ref; do
      chrome_recipe
      cp "$tmp/PKGBUILD" "$tmp/original"
      : >"$tmp/requests"
      if chrome_update "$mode"; then
        fail "$variant Chrome updater accepted $mode failure"
      fi
      cmp -s "$tmp/original" "$tmp/PKGBUILD" ||
        fail "$variant Chrome updater modified PKGBUILD after $mode"
      [[ "$(wc -l <"$tmp/requests")" -eq 1 ]] ||
        fail "$variant Chrome updater tried another tag after $mode"
      if compgen -G "$tmp/PKGBUILD.tmp.*" >/dev/null; then
        fail "$variant Chrome updater left a temporary recipe after $mode"
      fi
    done

    chrome_recipe
    cp "$tmp/PKGBUILD" "$tmp/original"
    : >"$tmp/requests"
    if PATH="$tmp/bin:$PATH" CHROME_TEST_MODE=good CHROME_REF="$ref" \
        CHROME_REQUESTED="$version" CHROME_URL_LOG="$tmp/requests" \
        bash "$script" invalid.version "$tmp/PKGBUILD" >"$tmp/output" 2>&1; then
      fail "$variant Chrome updater accepted an invalid version"
    fi
    cmp -s "$tmp/original" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater modified PKGBUILD after invalid version"
    [[ ! -s "$tmp/requests" ]] ||
      fail "$variant Chrome updater fetched metadata for an invalid version"
  done
  )
}

@test "Chrome Stable and Canary updaters update the matching FFmpeg pin" {
  (
  local tmp variant script version ref
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  chrome_mock_curl "$tmp"
  ref=0123456789abcdef0123456789abcdef01234567

  for variant in stable canary; do
    chrome_variant "$variant"
    chrome_recipe
    : >"$tmp/requests"
    chrome_update good || fail "$variant Chrome updater rejected valid metadata: $(cat "$tmp/output")"

    grep -Fxq "pkgver=$version" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater did not update version"
    grep -Fxq "_chromium_ffmpeg_ref=$ref" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater did not update the correct FFmpeg ref"
    grep -Fxq "# Chromium $version third_party/ffmpeg revision." "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater did not update the revision comment"
    grep -Fxq 'pkgrel=3' "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater changed release number"
    grep -Fxq "sha512sums=('untouched-checksum')" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater changed unrelated checksums"
    grep -Fxq "unrelated='keep me'" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater changed unrelated recipe content"
    [[ "$(wc -l <"$tmp/requests")" -eq 1 ]] ||
      fail "$variant Chrome updater made extra upstream requests on success"
    if compgen -G "$tmp/PKGBUILD.tmp.*" >/dev/null; then
      fail "$variant Chrome updater left a temporary recipe on success"
    fi
  done
  )
}

@test "Chrome updaters fall back only on a missing Chromium tag" {
  (
  local tmp variant script version ref preceding
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  chrome_mock_curl "$tmp"
  ref=0123456789abcdef0123456789abcdef01234567

  for variant in stable canary; do
    chrome_variant "$variant"
    # Canary's published version ends in .0; exercise its fallback logic with
    # a synthetic version that permits the nearest prior patch.
    if [[ "$variant" == canary ]]; then
      version=154.0.8024.2
      preceding=154.0.8024.1
    else
      preceding=153.0.8010.51
    fi
    chrome_recipe
    : >"$tmp/requests"
    chrome_update fallback ||
      fail "$variant Chrome updater refused a valid 404 fallback: $(cat "$tmp/output")"

    [[ "$(wc -l <"$tmp/requests")" -eq 2 ]] ||
      fail "$variant Chrome updater did not check exactly two tags"
    grep -Fq "/refs/tags/$preceding/DEPS?format=TEXT" "$tmp/requests" ||
      fail "$variant Chrome updater did not use the preceding tag"
    grep -Fxq "pkgver=$version" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater substituted the preceding tag as the Chrome version"
    grep -Fxq "_chromium_ffmpeg_ref=$ref" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater did not use the fallback revision"
    grep -Fxq "# Chromium $preceding third_party/ffmpeg revision." "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater misreported the source of the revision"
    grep -Fxq "unrelated='keep me'" "$tmp/PKGBUILD" ||
      fail "$variant Chrome updater lost unrelated recipe content on fallback"
  done
  )
}
