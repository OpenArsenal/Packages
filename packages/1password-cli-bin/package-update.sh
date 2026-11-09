#!/usr/bin/env bash
# Usage: PKGVER=x.x.x ./package-update.sh
set -euo pipefail

[[ "${PKGVER:-}" =~ ^[0-9][0-9A-Za-z.+_-]*$ ]] || {
  echo 'error: set PKGVER to the release version' >&2
  exit 2
}

arch=(x86_64 i686 arm aarch64)
_arch=(amd64 386 arm arm64)
work="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$work"' EXIT
sed_args=(-e "s/^pkgver=.*/pkgver=${PKGVER}/")

for a in "${!arch[@]}"; do
  zip="op_linux_${_arch[a]}_v${PKGVER}.zip"
  url="https://cache.agilebits.com/dist/1P/op2/pkg/v${PKGVER}/${zip}"
  wget -q -O "$work/$zip" "$url" || { echo "error: download failed: $zip" >&2; exit 1; }
  unzip -p "$work/$zip" op >"$work/op" || { echo "error: missing op in $zip" >&2; exit 1; }
  unzip -p "$work/$zip" op.sig >"$work/op.sig" || { echo "error: missing op.sig in $zip" >&2; exit 1; }
  gpgv -q "$work/op.sig" "$work/op" >/dev/null 2>&1 || { echo "error: bad signature: $zip" >&2; exit 1; }
  sum="$(sha256sum "$work/$zip")" || { echo "error: checksum failed: $zip" >&2; exit 1; }
  sum="${sum%% *}"
  [[ "$sum" =~ ^[[:xdigit:]]{64}$ ]] || { echo "error: invalid checksum: $zip" >&2; exit 1; }
  sed_args+=(-e "s/^sha256sums_${arch[a]}=.*/sha256sums_${arch[a]}=('${sum}')/")
  [[ "${arch[a]}" != arm ]] || sed_args+=(-e "s/^sha256sums_armv6h=.*/sha256sums_armv6h=('${sum}')/")
done

sed "${sed_args[@]}" PKGBUILD >"$work/PKGBUILD" || exit 1
mv -- "$work/PKGBUILD" PKGBUILD || exit 1
