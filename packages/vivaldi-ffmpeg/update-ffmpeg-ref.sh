#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: update-ffmpeg-ref.sh <chromium-version> [PKGBUILD] [vivaldi-major-version]

examples:
  ./update-ffmpeg-ref.sh 148.0.7778.221
  ./update-ffmpeg-ref.sh 148.0.7778.221 path/to/PKGBUILD
  ./update-ffmpeg-ref.sh 149.0.7800.0 PKGBUILD 8.1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

chromium_version="${1:-}"
pkgbuild="${2:-PKGBUILD}"
vivaldi_major_version="${3:-}"

if [[ -z "$chromium_version" ]]; then
  usage
  exit 2
fi

if [[ ! "$chromium_version" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
  echo "error: invalid Chromium version: $chromium_version" >&2
  echo "expected format like: 148.0.7778.221" >&2
  exit 2
fi

if [[ -n "$vivaldi_major_version" && ! "$vivaldi_major_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid Vivaldi major version: $vivaldi_major_version" >&2
  echo "expected format like: 8.0" >&2
  exit 2
fi

if [[ ! -f "$pkgbuild" ]]; then
  echo "error: PKGBUILD not found: $pkgbuild" >&2
  exit 1
fi

for cmd in curl base64 grep sed mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 1
  fi
done

deps_url="https://chromium.googlesource.com/chromium/src.git/+/refs/tags/${chromium_version}/DEPS?format=TEXT"

ffmpeg_ref="$(
  curl -fsSL "$deps_url" |
    base64 -d |
    grep -oE "['\"]ffmpeg_revision['\"][[:space:]]*:[[:space:]]*['\"][0-9a-f]{40}['\"]" |
    grep -oE "[0-9a-f]{40}" |
    head -n1
)"

if [[ ! "$ffmpeg_ref" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: could not resolve ffmpeg_revision for Chromium ${chromium_version}" >&2
  echo "checked: ${deps_url}" >&2
  exit 1
fi

tmp="$(mktemp)"
new_block="$(mktemp)"
trap 'rm -f "$tmp" "$new_block"' EXIT

cat >"$new_block" <<EOF
# Chromium ${chromium_version} third_party/ffmpeg submodule commit.
# For newer Chromium majors, use update-ffmpeg-ref.sh to update this commit and run updpkgsums.
_chromium_version=${chromium_version}
_chromium_ffmpeg_ref=${ffmpeg_ref}
EOF

# Preferred path: replace the managed 4-line block.
if grep -qE '^# Chromium .* third_party/ffmpeg submodule commit\.$' "$pkgbuild" &&
  grep -qE '^_chromium_version=' "$pkgbuild" &&
  grep -qE '^_chromium_ffmpeg_ref=' "$pkgbuild"; then

  sed -E "
    /^# Chromium .* third_party\/ffmpeg submodule commit\.$/{
      r $new_block
      N
      N
      N
      d
    }
  " "$pkgbuild" >"$tmp"

# Fallback: replace only variable lines if the comments are missing.
elif grep -qE '^_chromium_version=' "$pkgbuild" &&
  grep -qE '^_chromium_ffmpeg_ref=' "$pkgbuild"; then

  sed -E "
    s/^_chromium_version=.*/_chromium_version=${chromium_version}/
    s/^_chromium_ffmpeg_ref=.*/_chromium_ffmpeg_ref=${ffmpeg_ref}/
  " "$pkgbuild" >"$tmp"

else
  echo "error: could not find Chromium ffmpeg ref block in ${pkgbuild}" >&2
  exit 1
fi

mv "$tmp" "$pkgbuild"

if [[ -n "$vivaldi_major_version" ]]; then
  tmp="$(mktemp)"
  sed -E "s/^_vivaldi_major_version=.*/_vivaldi_major_version=${vivaldi_major_version}/" "$pkgbuild" >"$tmp"
  mv "$tmp" "$pkgbuild"
fi

trap - EXIT
rm -f "$new_block"

echo "Updated ${pkgbuild}:"
echo "  _chromium_version=${chromium_version}"
echo "  _chromium_ffmpeg_ref=${ffmpeg_ref}"
if [[ -n "$vivaldi_major_version" ]]; then
  echo "  _vivaldi_major_version=${vivaldi_major_version}"
fi
