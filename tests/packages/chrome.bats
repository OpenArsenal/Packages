#!/usr/bin/env bats
# Fail-closed Chrome FFmpeg revision updates, with all network requests mocked.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

@test "Chrome FFmpeg updaters preserve recipes on failed metadata and update valid revisions" {
  (
  local tmp variant mode source_pkg ref
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin"
  ref=0123456789abcdef0123456789abcdef01234567
  printf "  'ffmpeg_revision': '%s',\n" "$ref" | base64 >"$tmp/DEPS.base64"

  cat >"$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output="" url=""
while (( $# )); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -fsSL) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ -n "$output" && "$url" == *'/refs/tags/153.0.8010.60/DEPS?format=TEXT' ]] || exit 92
printf '%s\n' "$url" >>"$CHROME_CURL_LOG"
[[ "$CHROME_MODE" != transport ]] || exit 7
case "$CHROME_MODE" in
  invalid) printf '%%% not base64' >"$output" ;;
  missing) printf "'other_revision': 'abc',\n" | base64 >"$output" ;;
  success) cat "$CHROME_DEPS_B64" >"$output" ;;
  *) exit 93 ;;
esac
MOCK
  chmod +x "$tmp/bin/curl"

  for variant in google-chrome-ffmpeg google-chrome-canary-ffmpeg; do
    source_pkg="$root/packages/$variant/update-chrome-ref.sh"
    [[ -f "$source_pkg" ]] || fail "missing Chrome updater for $variant"

    for mode in transport invalid missing; do
      printf 'pkgname=chrome-test\npkgver=old\npkgrel=3\n# Chromium 0.0.0.0 third_party/ffmpeg revision.\n_chromium_ffmpeg_ref=old\n_keep=precious\n' >"$tmp/PKGBUILD"
      cp "$tmp/PKGBUILD" "$tmp/original"
      : >"$tmp/curl.log"
      if CHROME_MODE="$mode" CHROME_CURL_LOG="$tmp/curl.log" \
          CHROME_DEPS_B64="$tmp/DEPS.base64" PATH="$tmp/bin:$PATH" \
          bash "$source_pkg" 153.0.8010.60 "$tmp/PKGBUILD" >"$tmp/output" 2>&1; then
        fail "$variant accepted $mode Chromium metadata"
      fi
      cmp -s "$tmp/original" "$tmp/PKGBUILD" ||
        fail "$variant changed the recipe after $mode failure"
      [[ "$(wc -l <"$tmp/curl.log")" -eq 1 ]] ||
        fail "$variant made unexpected network requests after $mode failure"
    done

    : >"$tmp/curl.log"
    CHROME_MODE=success CHROME_CURL_LOG="$tmp/curl.log" \
      CHROME_DEPS_B64="$tmp/DEPS.base64" PATH="$tmp/bin:$PATH" \
      bash "$source_pkg" 153.0.8010.60 "$tmp/PKGBUILD" >"$tmp/output" 2>&1 ||
      fail "$variant refused valid Chromium metadata: $(cat "$tmp/output")"
    grep -Fxq 'pkgver=153.0.8010.60' "$tmp/PKGBUILD" ||
      fail "$variant did not update Chrome version"
    grep -Fxq "_chromium_ffmpeg_ref=$ref" "$tmp/PKGBUILD" ||
      fail "$variant did not update the FFmpeg revision"
    grep -Fxq '# Chromium 153.0.8010.60 third_party/ffmpeg revision.' "$tmp/PKGBUILD" ||
      fail "$variant did not update the pinned version comment"
    grep -Fxq '_keep=precious' "$tmp/PKGBUILD" ||
      fail "$variant changed unrelated recipe data"
    grep -Fxq 'pkgrel=3' "$tmp/PKGBUILD" ||
      fail "$variant changed the package release unexpectedly"
    [[ "$(wc -l <"$tmp/curl.log")" -eq 1 ]] ||
      fail "$variant requested an unexpected Chromium tag"
  done
  )
}
