#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 1
exec bash "$here/../../.mise/lib/pkg/chrome-ref.sh" stable "$here/PKGBUILD" "$@"
