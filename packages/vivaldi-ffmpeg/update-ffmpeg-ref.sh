#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: update-ffmpeg-ref.sh <chromium-version> [PKGBUILD] [vivaldi-major-version]

Resolve Chromium's third_party/ffmpeg commit for the supplied Chromium tag,
then update _chromium_version and _chromium_ffmpeg_ref in the PKGBUILD.

If the exact Chromium tag is not public, the resolver falls back to the nearest
lower patch tag on the same Chromium branch. This handles Vivaldi ESR builds
whose reported Chromium version can be ahead of Chromium's public src.git tags.

examples:
  ./update-ffmpeg-ref.sh 148.0.7778.221
  ./update-ffmpeg-ref.sh 148.0.7778.221 path/to/PKGBUILD
  ./update-ffmpeg-ref.sh 149.0.7800.0 PKGBUILD 8.1
USAGE
}

err() {
  printf 'error: %s\n' "$*" >&2
}

warn() {
  printf 'warning: %s\n' "$*" >&2
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
  local tmp http_code curl_status

  tmp="$(mktemp)"
  http_code="$(curl -sS -L -w '%{http_code}' -o "$tmp" "$url")"
  curl_status=$?

  if (( curl_status != 0 )); then
    rm -f "$tmp"
    return "$curl_status"
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$tmp"
    return 22
  fi

  cat "$tmp"
  rm -f "$tmp"
}

fetch_gitiles_text() {
  # Gitiles returns file ?format=TEXT bodies as base64 encoded text.
  local url=$1
  fetch_text "$url" | base64_decode
}

chromium_deps_url() {
  local chromium_version=$1
  printf 'https://chromium.googlesource.com/chromium/src.git/+/refs/tags/%s/DEPS?format=TEXT\n' "$chromium_version"
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
  local major minor build requested_patch patch candidate deps_url deps ffmpeg_ref status

  IFS=. read -r major minor build requested_patch <<<"$chromium_version"

  for (( patch = requested_patch; patch >= 0; patch-- )); do
    candidate="${major}.${minor}.${build}.${patch}"
    deps_url="$(chromium_deps_url "$candidate")"

    if deps="$(fetch_gitiles_text "$deps_url" 2>/dev/null)"; then
      ffmpeg_ref="$(printf '%s\n' "$deps" | extract_ffmpeg_ref_from_deps)"

      if [[ ! "$ffmpeg_ref" =~ ^[0-9a-f]{40}$ ]]; then
        err "could not resolve ffmpeg_revision for Chromium ${candidate}"
        printf 'checked: %s\n' "$deps_url" >&2
        return 1
      fi

      if [[ "$candidate" != "$chromium_version" ]]; then
        warn "Chromium tag ${chromium_version} was not public; using DEPS from nearest lower public tag ${candidate}"
      fi

      # stdout is parsed by main(): <ffmpeg_ref><TAB><deps_version>
      printf '%s\t%s\n' "$ffmpeg_ref" "$candidate"
      return 0
    else
      status=$?
      # curl uses 22 for HTTP errors. Those are expected when probing missing tags.
      # Other failures usually mean DNS, TLS, or connectivity problems; do not hide them
      # behind hundreds of fallback attempts.
      if (( status != 22 )); then
        err "could not fetch Chromium DEPS for ${candidate}"
        printf 'checked: %s\n' "$deps_url" >&2
        return 1
      fi
    fi
  done

  err "could not fetch Chromium DEPS for ${chromium_version} or any lower patch tag on ${major}.${minor}.${build}.x"
  printf 'first checked: %s\n' "$(chromium_deps_url "$chromium_version")" >&2
  printf 'last checked: %s\n' "$(chromium_deps_url "${major}.${minor}.${build}.0")" >&2
  return 1
}

update_pkgbuild() {
  local pkgbuild=$1
  local chromium_version=$2
  local ffmpeg_ref=$3
  local vivaldi_major_version=$4
  local deps_version=$5
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
    -v vivaldi_major_version="$vivaldi_major_version" \
    -v deps_version="$deps_version" '
      /^# Chromium .* third_party\/ffmpeg submodule commit/ {
        if (deps_version != "" && deps_version != chromium_version) {
          print "# Chromium " chromium_version " third_party/ffmpeg submodule commit; DEPS resolved from public tag " deps_version "."
        } else {
          print "# Chromium " chromium_version " third_party/ffmpeg submodule commit."
        }
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
  local resolve_result ffmpeg_ref deps_version

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

  resolve_result="$(resolve_ffmpeg_ref "$chromium_version")"
  ffmpeg_ref="${resolve_result%%$'\t'*}"
  deps_version="${resolve_result#*$'\t'}"

  update_pkgbuild "$pkgbuild" "$chromium_version" "$ffmpeg_ref" "$vivaldi_major_version" "$deps_version"

  printf 'Updated %s:\n' "$pkgbuild"
  printf '  _chromium_version=%s\n' "$chromium_version"
  printf '  _chromium_ffmpeg_ref=%s\n' "$ffmpeg_ref"
  if [[ "$deps_version" != "$chromium_version" ]]; then
    printf '  DEPS resolved from Chromium public tag %s\n' "$deps_version"
  fi
  if [[ -n "$vivaldi_major_version" ]]; then
    printf '  _vivaldi_major_version=%s\n' "$vivaldi_major_version"
  fi
  printf '\nRun updpkgsums next so the sigs.base64 checksum tracks the new ffmpeg ref.\n'
}

main "$@"
