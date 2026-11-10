#!/usr/bin/env bats
# File-backed integration coverage for both Chromium FFmpeg revision updaters.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

@test "FFmpeg updaters fall back on HTTP 404 but stop on other HTTP errors" {
  (
  local tmp variant mode source_pkg ref
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin"
  ref=0123456789abcdef0123456789abcdef01234567
  printf "  'ffmpeg_revision': '%s',\n" "$ref" | base64 >"$tmp/deps.base64"

  cat >"$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output="" url=""
while (( $# )); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    -sS|-L) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 91
printf '%s\n' "$url" >>"$FFMPEG_CURL_LOG"
[[ "${FFMPEG_FAILURE_MODE:-}" != transport ]] || exit 56
if [[ "$url" == *'148.0.7778.221'* ]]; then
  code="${FFMPEG_HTTP_STATUS:-404}"
else
  code=200
fi
if [[ "$code" == 200 ]]; then
  case "${FFMPEG_FAILURE_MODE:-}" in
    decode) printf 'not@@base64' >"$output" ;;
    missing-ref) printf 'no revision here\n' | base64 >"$output" ;;
    *) cat "$FFMPEG_DEPS_B64" >"$output" ;;
  esac
else
  printf 'upstream error page\n' >"$output"
fi
printf '%s' "$code"
MOCK
  chmod +x "$tmp/bin/curl"

  for variant in chromium-ffmpeg vivaldi-ffmpeg; do
    source_pkg="$root/packages/$variant/update-ffmpeg-ref.sh"
    [[ -f "$source_pkg" ]] || fail "missing $variant updater"

    for mode in 500 403 429; do
      printf '_chromium_version=old\n_chromium_ffmpeg_ref=old\n_keep=original\n' >"$tmp/PKGBUILD"
      cp "$tmp/PKGBUILD" "$tmp/original"
      : >"$tmp/curl.log"
      if FFMPEG_HTTP_STATUS="$mode" FFMPEG_CURL_LOG="$tmp/curl.log" \
          FFMPEG_DEPS_B64="$tmp/deps.base64" PATH="$tmp/bin:$PATH" \
          bash "$source_pkg" 148.0.7778.221 "$tmp/PKGBUILD" >"$tmp/output" 2>&1; then
        fail "$variant incorrectly fell back after HTTP $mode"
      fi
      cmp -s "$tmp/original" "$tmp/PKGBUILD" ||
        fail "$variant changed PKGBUILD after HTTP $mode"
      [[ "$(wc -l <"$tmp/curl.log")" -eq 1 ]] ||
        fail "$variant probed an older tag after HTTP $mode"
      grep -Fq '148.0.7778.221' "$tmp/curl.log" ||
        fail "$variant did not request the intended Chromium tag"
    done

    for mode in transport decode missing-ref; do
      printf '_chromium_version=old\n_chromium_ffmpeg_ref=old\n_keep=original\n' >"$tmp/PKGBUILD"
      cp "$tmp/PKGBUILD" "$tmp/original"
      : >"$tmp/curl.log"
      if FFMPEG_FAILURE_MODE="$mode" FFMPEG_HTTP_STATUS=200 \
          FFMPEG_CURL_LOG="$tmp/curl.log" FFMPEG_DEPS_B64="$tmp/deps.base64" \
          PATH="$tmp/bin:$PATH" bash "$source_pkg" 148.0.7778.221 "$tmp/PKGBUILD" \
          >"$tmp/output" 2>&1; then
        fail "$variant accepted $mode failure"
      fi
      cmp -s "$tmp/original" "$tmp/PKGBUILD" ||
        fail "$variant changed PKGBUILD after $mode failure"
      [[ "$(wc -l <"$tmp/curl.log")" -eq 1 ]] ||
        fail "$variant attempted fallback after $mode failure"
    done

    printf '_chromium_version=old\n_chromium_ffmpeg_ref=old\n_keep=original\n' >"$tmp/PKGBUILD"
    : >"$tmp/curl.log"
    FFMPEG_HTTP_STATUS=404 FFMPEG_CURL_LOG="$tmp/curl.log" \
      FFMPEG_DEPS_B64="$tmp/deps.base64" PATH="$tmp/bin:$PATH" \
      bash "$source_pkg" 148.0.7778.221 "$tmp/PKGBUILD" >"$tmp/output" 2>&1 ||
      fail "$variant refused valid 404 fallback: $(cat "$tmp/output")"
    [[ "$(wc -l <"$tmp/curl.log")" -eq 2 ]] ||
      fail "$variant did not check exactly the requested and previous tags"
    grep -Fq '148.0.7778.220' "$tmp/curl.log" ||
      fail "$variant did not check the preceding public tag"
    grep -Fxq '_chromium_version=148.0.7778.221' "$tmp/PKGBUILD" ||
      fail "$variant lost the requested Chromium version on fallback"
    grep -Fxq "_chromium_ffmpeg_ref=$ref" "$tmp/PKGBUILD" ||
      fail "$variant did not use the older public tag's revision"
    grep -Fxq '_keep=original' "$tmp/PKGBUILD" ||
      fail "$variant changed unrelated PKGBUILD content"
    grep -Fq 'was not public' "$tmp/output" ||
      fail "$variant did not explain the genuine 404 fallback"
  done
  )
}
