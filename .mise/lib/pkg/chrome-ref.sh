#!/usr/bin/env bash
# Shared maintenance helper for the Chrome Stable and Canary FFmpeg recipes.
# Called by each recipe's update-chrome-ref.sh entrypoint.
set -euo pipefail

usage() {
  printf 'usage: update-chrome-ref.sh <chrome-version> [PKGBUILD]\n' >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if (( $# != 3 && $# != 4 )); then
  usage
  exit 2
fi

channel="$1"
pkgbuild="$2"
requested="$3"
if (( $# == 4 )); then
  pkgbuild="$4"
fi

[[ "$channel" == stable || "$channel" == canary ]] || fail "invalid Chrome channel: $channel"
[[ "$requested" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail "invalid Chrome version: $requested"
[[ -f "$pkgbuild" && ! -L "$pkgbuild" ]] || fail "missing or symlinked PKGBUILD: $pkgbuild"
grep -Fxq "_channel=$channel" "$pkgbuild" ||
  fail "PKGBUILD is not for Chrome $channel"

# Refuse ambiguous files before doing any network work or writing anything.
for field in pkgver _chromium_ffmpeg_ref; do
  [[ "$(grep -c "^$field=" "$pkgbuild")" == 1 ]] ||
    fail "expected exactly one $field assignment in $pkgbuild"
done

fetch_deps() {
  local tag="$1" body code url decoded
  url="https://chromium.googlesource.com/chromium/src.git/+/refs/tags/$tag/DEPS?format=TEXT"
  body="$(mktemp)" || return 1

  if ! code="$(curl -sS -L -w '%{http_code}' -o "$body" "$url")"; then
    rm -f -- "$body"
    printf 'error: could not download Chromium DEPS for %s\n' "$tag" >&2
    return 1
  fi

  if [[ "$code" == 404 ]]; then
    rm -f -- "$body"
    return 44
  fi
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    rm -f -- "$body"
    printf 'error: Chromium DEPS request failed for %s (HTTP %s)\n' "$tag" "$code" >&2
    return 1
  fi

  if ! decoded="$(base64 -d <"$body" 2>/dev/null)"; then
    rm -f -- "$body"
    printf 'error: invalid base64 Chromium DEPS for %s\n' "$tag" >&2
    return 1
  fi
  rm -f -- "$body"
  printf '%s\n' "$decoded"
}

extract_ref() {
  # Chromium normally pins the commit via vars['ffmpeg_revision'].
  # Also accept the direct submodule form used in some older DEPS files.
  printf '%s\n' "$1" | sed -nE \
    -e "s/^[[:space:]]*['\"]ffmpeg_revision['\"][[:space:]]*:[[:space:]]*['\"]([0-9a-f]{40})['\"].*/\1/p" \
    -e "s/.*['\"]src\/third_party\/ffmpeg['\"].*@['\"]([0-9a-f]{40})['\"].*/\1/p" |
    sed -n '1p'
}

IFS=. read -r major minor build requested_patch <<<"$requested"
ref=""
resolved_tag=""
for (( patch = 10#$requested_patch; patch >= 0; patch-- )); do
  tag="$major.$minor.$build.$patch"
  if deps="$(fetch_deps "$tag")"; then
    ref="$(extract_ref "$deps")"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] ||
      fail "missing or invalid ffmpeg_revision in Chromium DEPS for $tag"
    resolved_tag="$tag"
    break
  else
    status=$?
    # Only an actual 404 allows trying a lower patch tag. No fallback on
    # transport, authentication, throttling, decode or parse failures.
    (( status == 44 )) || exit 1
  fi
done

[[ -n "$resolved_tag" ]] ||
  fail "no public Chromium DEPS tag found for $requested"

# Stage beside PKGBUILD, retaining permissions; only replace after every
# upstream lookup, checksum/ref validation and rewrite have succeeded.
tmp="$(mktemp "$pkgbuild.tmp.XXXXXXXX")" || fail "cannot stage PKGBUILD update"
trap 'rm -f -- "$tmp"' EXIT
cp -p -- "$pkgbuild" "$tmp" || fail "cannot preserve PKGBUILD permissions"
awk -v version="$requested" -v ref="$ref" -v tag="$resolved_tag" '
  /^pkgver=/ { print "pkgver=" version; next }
  /^_chromium_ffmpeg_ref=/ { print "_chromium_ffmpeg_ref=" ref; next }
  /^# Chromium [0-9.]+ third_party\/ffmpeg revision\./ {
    print "# Chromium " tag " third_party/ffmpeg revision."
    next
  }
  { print }
' "$pkgbuild" >"$tmp" || fail "could not rewrite PKGBUILD"
mv -- "$tmp" "$pkgbuild" || fail "could not install updated PKGBUILD"
trap - EXIT

printf 'Updated Chrome %s: %s\n' "$channel" "$pkgbuild"
printf '  pkgver=%s\n  _chromium_ffmpeg_ref=%s\n' "$requested" "$ref"
if [[ "$resolved_tag" != "$requested" ]]; then
  printf '  DEPS came from preceding public Chromium tag %s\n' "$resolved_tag"
fi
printf 'Run updpkgsums and makepkg --printsrcinfo before publishing.\n'
