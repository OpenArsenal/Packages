#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: update-ffmpeg-ref.sh <chromium-version> [PKGBUILD] [vivaldi-major-version]

Resolve Chromium's third_party/ffmpeg commit for the supplied Chromium tag,
then update _chromium_version and _chromium_ffmpeg_ref in the PKGBUILD.

examples:
  ./update-ffmpeg-ref.sh 148.0.7778.221
  ./update-ffmpeg-ref.sh 148.0.7778.221 path/to/PKGBUILD
  ./update-ffmpeg-ref.sh 149.0.7800.0 PKGBUILD 8.1
USAGE
}

err() {
  printf 'error: %s\n' "$*" >&2
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

base64_decode() {
  # GNU base64 uses -d; BSD/macOS base64 uses -D.
  if base64 --help 2>&1 | grep -q -- '-d'; then
    base64 -d
  else
    base64 -D
  fi
}

fetch_text() {
  local url=$1
  curl -fsSL "$url"
}

fetch_gitiles_text() {
  # Gitiles returns ?format=TEXT bodies as base64 encoded text.
  local url=$1
  fetch_text "$url" | base64_decode
}

extract_ffmpeg_ref_from_deps() {
  # Chromium DEPS usually pins ffmpeg through vars['ffmpeg_revision'].
  # Keep this slightly broader than a single exact spelling so future whitespace
  # or quote-style changes do not break the updater.
  sed -nE \
    -e "s/^[[:space:]]*['\"]ffmpeg_revision['\"][[:space:]]*:[[:space:]]*['\"]([0-9a-f]{40})['\"].*/\1/p" \
    -e "s/.*['\"]src\/third_party\/ffmpeg['\"].*@['\"]([0-9a-f]{40})['\"].*/\1/p" |
    head -n1
}

resolve_ffmpeg_ref() {
  local chromium_version=$1
  local deps_url="https://chromium.googlesource.com/chromium/src.git/+/refs/tags/${chromium_version}/DEPS?format=TEXT"
  local deps ffmpeg_ref

  deps="$(fetch_gitiles_text "$deps_url")" || {
    err "could not fetch Chromium DEPS for ${chromium_version}"
    printf 'checked: %s\n' "$deps_url" >&2
    return 1
  }

  ffmpeg_ref="$(printf '%s\n' "$deps" | extract_ffmpeg_ref_from_deps)"

  if [[ ! "$ffmpeg_ref" =~ ^[0-9a-f]{40}$ ]]; then
    err "could not resolve ffmpeg_revision for Chromium ${chromium_version}"
    printf 'checked: %s\n' "$deps_url" >&2
    return 1
  fi

  printf '%s\n' "$ffmpeg_ref"
}

update_pkgbuild() {
  local pkgbuild=$1
  local chromium_version=$2
  local ffmpeg_ref=$3
  local vivaldi_major_version=$4
  local tmp

  if ! grep -qE '^_chromium_version=' "$pkgbuild"; then
    err "could not find _chromium_version= in ${pkgbuild}"
    return 1
  fi

  if ! grep -qE '^_chromium_ffmpeg_ref=' "$pkgbuild"; then
    err "could not find _chromium_ffmpeg_ref= in ${pkgbuild}"
    return 1
  fi

  if [[ -n "$vivaldi_major_version" ]] && ! grep -qE '^_vivaldi_major_version=' "$pkgbuild"; then
    err "could not find _vivaldi_major_version= in ${pkgbuild}"
    return 1
  fi

  tmp="$(mktemp)"
  awk \
    -v chromium_version="$chromium_version" \
    -v ffmpeg_ref="$ffmpeg_ref" \
    -v vivaldi_major_version="$vivaldi_major_version" '
      /^# Chromium .* third_party\/ffmpeg submodule commit\.$/ {
        print "# Chromium " chromium_version " third_party/ffmpeg submodule commit."
        next
      }
      /^_chromium_version=/ {
        print "_chromium_version=" chromium_version
        next
      }
      /^_chromium_ffmpeg_ref=/ {
        print "_chromium_ffmpeg_ref=" ffmpeg_ref
        next
      }
      vivaldi_major_version != "" && /^_vivaldi_major_version=/ {
        print "_vivaldi_major_version=" vivaldi_major_version
        next
      }
      { print }
    ' "$pkgbuild" >"$tmp"

  mv "$tmp" "$pkgbuild"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  local chromium_version="${1:-}"
  local pkgbuild="${2:-PKGBUILD}"
  local vivaldi_major_version="${3:-}"
  local ffmpeg_ref

  if [[ -z "$chromium_version" ]]; then
    usage
    exit 2
  fi

  if [[ ! "$chromium_version" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    err "invalid Chromium version: $chromium_version"
    printf 'expected format like: 148.0.7778.221\n' >&2
    exit 2
  fi

  if [[ -n "$vivaldi_major_version" && ! "$vivaldi_major_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    err "invalid Vivaldi major version: $vivaldi_major_version"
    printf 'expected format like: 8.0\n' >&2
    exit 2
  fi

  if [[ ! -f "$pkgbuild" ]]; then
    err "PKGBUILD not found: $pkgbuild"
    exit 1
  fi

  for cmd in awk base64 curl grep mktemp sed; do
    if ! have_cmd "$cmd"; then
      err "required command not found: $cmd"
      exit 1
    fi
  done

  ffmpeg_ref="$(resolve_ffmpeg_ref "$chromium_version")"
  update_pkgbuild "$pkgbuild" "$chromium_version" "$ffmpeg_ref" "$vivaldi_major_version"

  printf 'Updated %s:\n' "$pkgbuild"
  printf '  _chromium_version=%s\n' "$chromium_version"
  printf '  _chromium_ffmpeg_ref=%s\n' "$ffmpeg_ref"
  if [[ -n "$vivaldi_major_version" ]]; then
    printf '  _vivaldi_major_version=%s\n' "$vivaldi_major_version"
  fi
  printf '\nRun updpkgsums next so the sigs.base64 checksum tracks the new ffmpeg ref.\n'
}

main "$@"
