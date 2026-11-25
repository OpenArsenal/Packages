#!/usr/bin/env bats
# Exercise the public --latest entrypoints without network or Arch build tools.
setup() {
  load 'test_helper/common'
  bats_repo_setup
}

codec_fixture() {
  local name="$1" target="$2" script="$3"
  fixture="$BATS_TEST_TMPDIR/fixture"
  dir="$fixture/packages/$name"
  mkdir -p "$dir" "$fixture/.mise/lib/pkg" "$fixture/.mise/scripts" "$fixture/bin"
  cp "$root/.mise/lib/pkg/"{update,chrome-ref}.sh "$fixture/.mise/lib/pkg/"
  cp "$root/.mise/scripts/codec-sync.py" "$fixture/.mise/scripts/"
  cp "$root/packages/$name/$script" "$dir/"
  cp "$root/packages/$name/.nvchecker.toml" "$dir/"
  export PATH="$fixture/bin:$PATH" TARGET_VERSION="$target"
  export VIVALDI_VERSION=8.3.4191.47
  export CODEC_MODE=success
  export CODEC_REF=0123456789abcdef0123456789abcdef01234567
  export CODEC_NAME="$name"
  export CODEC_LOG="$fixture/calls"

  cat >"$fixture/bin/nvchecker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --file && -f "$2" ]] || exit 90
printf 'nvchecker\n' >>"$CODEC_LOG"
[[ "$CODEC_MODE" != query-fail ]] || exit 42
printf '{"event":"updated","name":"%s","version":"%s"}\n' "$CODEC_NAME" "$TARGET_VERSION"
if [[ "$CODEC_NAME" == vivaldi-ffmpeg ]]; then
  printf '{"event":"updated","name":"%s:vivaldi","version":"%s"}\n' "$CODEC_NAME" "$VIVALDI_VERSION"
fi
MOCK

  cat >"$fixture/bin/vercmp" <<'MOCK'
#!/usr/bin/env python3
import sys
a, b = (tuple(map(int, v.split("."))) for v in sys.argv[1:])
print((a > b) - (a < b))
MOCK

  cat >"$fixture/bin/curl" <<'MOCK'
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
[[ -n "$output" && "$url" == *'/DEPS?format=TEXT' ]] || exit 91
printf '%s\n' "$url" >>"$CODEC_LOG"
if [[ "$CODEC_MODE" == ref-fail ]]; then
  printf '503'
else
  printf "  'ffmpeg_revision': '%s',\n" "$CODEC_REF" | base64 >"$output"
  printf '200'
fi
MOCK

  cat >"$fixture/bin/updpkgsums" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${SRCDEST:-}" && -d "$SRCDEST" && -f PKGBUILD ]] || exit 92
printf 'checksums\n' >>"$CODEC_LOG"
sed -i "s/^sha256sums=.*/sha256sums=('refreshed')/" PKGBUILD
[[ "$CODEC_MODE" != checksum-fail ]] || exit 43
MOCK

  cat >"$fixture/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --printsrcinfo ]] || exit 93
source ./PKGBUILD
[[ "$CODEC_MODE" != metadata-fail ]] || exit 44
if [[ "$CODEC_MODE" == wrong-metadata ]]; then pkgver=0; fi
printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n\tsource = %s\n\tsha256sums = %s\n\npkgname = %s\n' \
  "$pkgname" "$pkgver" "$pkgrel" "${source[0]}" "${sha256sums[0]}" "$pkgname"
MOCK
  chmod +x "$fixture/bin/"*

  if [[ "$name" == vivaldi-ffmpeg || "$name" == chromium-ffmpeg ]]; then
    cat >"$dir/PKGBUILD" <<'RECIPE'
pkgname=vivaldi-ffmpeg
_ffmpeg_pkgver=8.1.1
_chromium_version=156.0.8078.91
_vivaldi_major_version=8.0
pkgver=${_ffmpeg_pkgver}_${_chromium_version}
pkgrel=3
# Chromium 156.0.8078.91 third_party/ffmpeg submodule commit.
_chromium_ffmpeg_ref=0000000000000000000000000000000000000000
source=("sigs.base64::https://example.invalid/${_chromium_ffmpeg_ref}")
sha256sums=('old')
RECIPE
    sed -i "s/^pkgname=.*/pkgname=$name/" "$dir/PKGBUILD"
  else
    cat >"$dir/PKGBUILD" <<'RECIPE'
pkgname=google-chrome-ffmpeg
pkgver=158.0.8127.36
pkgrel=3
_channel=stable
# Chromium 158.0.8127.36 third_party/ffmpeg revision.
_chromium_ffmpeg_ref=0000000000000000000000000000000000000000
source=("https://example.invalid/${_chromium_ffmpeg_ref}.tar.gz")
sha256sums=('old')
RECIPE
  fi
  (cd "$dir" && makepkg --printsrcinfo) >"$dir/.SRCINFO"
  cp "$dir/PKGBUILD" "$fixture/original-build"
  cp "$dir/.SRCINFO" "$fixture/original-info"
}

@test "Chrome codec latest synchronizes version source checksums and metadata" {
  codec_fixture google-chrome-ffmpeg 158.0.8127.88 update-chrome-ref.sh
  run bash "$dir/update-chrome-ref.sh" --latest
  [[ "$status" -eq 0 ]] || fail "$output"
  grep -Fxq 'pkgver=158.0.8127.88' "$dir/PKGBUILD" || fail 'Chrome version not updated'
  grep -Fxq "_chromium_ffmpeg_ref=$CODEC_REF" "$dir/PKGBUILD" || fail 'Chrome ref not updated'
  grep -Fxq 'pkgrel=1' "$dir/PKGBUILD" || fail 'pkgrel not reset'
  grep -Fq "sha256sums=('refreshed')" "$dir/PKGBUILD" || fail 'checksums not updated'
  grep -Fq 'pkgver = 158.0.8127.88' "$dir/.SRCINFO" || fail 'SRCINFO version not updated'
  grep -Fq "$CODEC_REF" "$dir/.SRCINFO" || fail 'SRCINFO ref not updated'
}

@test "Vivaldi codec latest synchronizes FFmpeg Chromium and browser installation version" {
  codec_fixture vivaldi-ffmpeg 8.1.2_156.0.8078.99 update-ffmpeg-ref.sh
  run bash "$dir/update-ffmpeg-ref.sh" --latest
  [[ "$status" -eq 0 ]] || fail "$output"
  grep -Fxq '_ffmpeg_pkgver=8.1.2' "$dir/PKGBUILD" || fail 'FFmpeg version not updated'
  grep -Fxq '_chromium_version=156.0.8078.99' "$dir/PKGBUILD" || fail 'Chromium version not updated'
  grep -Fxq '_vivaldi_major_version=8.3' "$dir/PKGBUILD" || fail 'Vivaldi install suffix not updated'
  grep -Fxq "_chromium_ffmpeg_ref=$CODEC_REF" "$dir/PKGBUILD" || fail 'Vivaldi ref not updated'
  grep -Fq 'pkgver = 8.1.2_156.0.8078.99' "$dir/.SRCINFO" || fail 'combined version not updated'
}

@test "Codec synchronization preserves recipe files after upstream or generation failures" {
  codec_fixture vivaldi-ffmpeg 8.1.2_156.0.8078.99 update-ffmpeg-ref.sh
  local mode
  for mode in query-fail ref-fail checksum-fail metadata-fail wrong-metadata; do
    export CODEC_MODE="$mode"
    run bash "$dir/update-ffmpeg-ref.sh" --latest
    [[ "$status" -ne 0 ]] || fail "accepted $mode"
    cmp -s "$fixture/original-build" "$dir/PKGBUILD" || fail "PKGBUILD changed after $mode"
    cmp -s "$fixture/original-info" "$dir/.SRCINFO" || fail "SRCINFO changed after $mode"
  done
  export CODEC_MODE=success TARGET_VERSION=8.1.2_155.0.8000.1
  run bash "$dir/update-ffmpeg-ref.sh" --latest
  [[ "$status" -ne 0 && "$output" == *'refusing to downgrade'* ]] || fail "accepted Chromium downgrade: $output"
  cmp -s "$fixture/original-build" "$dir/PKGBUILD" || fail 'downgrade modified recipe'
  cmp -s "$fixture/original-info" "$dir/.SRCINFO" || fail 'downgrade modified metadata'
  export TARGET_VERSION=9.0_156.0.8078.99
  run bash "$dir/update-ffmpeg-ref.sh" --latest
  [[ "$status" -ne 0 && "$output" == *'FFmpeg major changed'* ]] || fail "accepted ABI change: $output"
  cmp -s "$fixture/original-build" "$dir/PKGBUILD" || fail 'ABI change modified recipe'
  cmp -s "$fixture/original-info" "$dir/.SRCINFO" || fail 'ABI change modified metadata'
}

@test "Codec synchronization increments pkgrel when repairing an unchanged version" {
  codec_fixture google-chrome-ffmpeg 158.0.8127.36 update-chrome-ref.sh
  run bash "$dir/update-chrome-ref.sh" --latest
  [[ "$status" -eq 0 ]] || fail "$output"
  grep -Fxq 'pkgrel=4' "$dir/PKGBUILD" || fail 'pkgrel not incremented after pin repair'
  grep -Fq 'pkgrel = 4' "$dir/.SRCINFO" || fail 'pkgrel metadata not updated'
  cp "$dir/PKGBUILD" "$fixture/repaired-build"
  cp "$dir/.SRCINFO" "$fixture/repaired-info"
  run bash "$dir/update-chrome-ref.sh" --latest
  [[ "$status" -eq 0 ]] || fail "$output"
  cmp -s "$fixture/repaired-build" "$dir/PKGBUILD" || fail 'unchanged recipe was modified'
  cmp -s "$fixture/repaired-info" "$dir/.SRCINFO" || fail 'unchanged metadata was modified'
}
