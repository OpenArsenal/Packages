#!/usr/bin/env bash
set -euo pipefail

# Use the same upstream version sources as pkg:update. Explicit versions
# retain the existing reference-only maintenance interface.
if [[ "${1:-}" == --latest ]]; then
  (( $# == 1 )) || { echo 'usage: updater --latest' >&2; exit 2; }
  here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
  exec python3 "$here/../../.mise/scripts/codec-sync.py" "$here"
fi
here="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 1
exec bash "$here/../../.mise/lib/pkg/chrome-ref.sh" stable "$here/PKGBUILD" "$@"
