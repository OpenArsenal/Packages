#!/usr/bin/env bash
# Resolve Chrome's exact Chromium FFmpeg commit before updating a recipe.
# Usage: update-chrome-ref.sh <chrome-version> [PKGBUILD]
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'usage: %s <chrome-version> [PKGBUILD]\n' "$0"
  exit 0
fi

version="${1:-}"
pkgbuild="${2:-PKGBUILD}"
if (( $# < 1 || $# > 2 )) || [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
  printf 'usage: %s <chrome-version> [PKGBUILD]\n' "$0" >&2
  exit 2
fi
[[ -f "$pkgbuild" ]] || die "PKGBUILD not found: $pkgbuild"

# A partial or ambiguous fixture is not safe to rewrite. Validate first.
for field in pkgver _chromium_ffmpeg_ref; do
  [[ "$(grep -c "^$field=" "$pkgbuild")" == 1 ]] ||
    die "expected exactly one $field= assignment in $pkgbuild"
done

# Work beside the recipe so the final move stays on the same filesystem.
work="$(mktemp -d -- "$(dirname -- "$pkgbuild")/.chrome-ref.XXXXXXXX")" ||
  die 'unable to create temporary directory'
trap 'rm -rf -- "$work"' EXIT

url="https://chromium.googlesource.com/chromium/src.git/+/refs/tags/${version}/DEPS?format=TEXT"
curl -fsSL -o "$work/DEPS.base64" "$url" ||
  die "could not fetch Chromium DEPS for $version"
base64 -d <"$work/DEPS.base64" >"$work/DEPS" ||
  die "invalid Chromium DEPS encoding for $version"

ref="$(sed -nE \
  -e "s/^[[:space:]]*['\"]ffmpeg_revision['\"][[:space:]]*:[[:space:]]*['\"]([0-9a-f]{40})['\"].*/\1/p" \
  -e "s/.*['\"]src\/third_party\/ffmpeg['\"].*@['\"]([0-9a-f]{40})['\"].*/\1/p" \
  "$work/DEPS")"
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] ||
  die "could not resolve a unique FFmpeg revision for Chromium $version"

awk -v version="$version" -v ref="$ref" '
  /^pkgver=/ { print "pkgver=" version; next }
  /^_chromium_ffmpeg_ref=/ { print "_chromium_ffmpeg_ref=" ref; next }
  /^# Chromium .* third_party\/ffmpeg revision\.$/ {
    print "# Chromium " version " third_party/ffmpeg revision."
    next
  }
  { print }
' "$pkgbuild" >"$work/PKGBUILD" ||
  die "could not write updated recipe: $pkgbuild"
chmod --reference="$pkgbuild" "$work/PKGBUILD" ||
  die "could not preserve recipe permissions: $pkgbuild"
mv -- "$work/PKGBUILD" "$pkgbuild" ||
  die "could not replace recipe: $pkgbuild"

printf 'Updated %s to Chromium %s FFmpeg revision %s\n' "$pkgbuild" "$version" "$ref"
printf 'Now run updpkgsums and regenerate .SRCINFO before publishing.\n'
