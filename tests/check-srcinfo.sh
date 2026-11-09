#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
(( $# > 0 )) || set -- "$root"/packages/*
tmp="$(mktemp)" || exit 1
trap 'rm -f -- "$tmp"' EXIT
failed=0

for dir in "$@"; do
  [[ -f "$dir/PKGBUILD" ]] || continue
  if [[ ! -f "$dir/.SRCINFO" ]]; then
    echo "error: missing .SRCINFO: $dir" >&2
    failed=1
    continue
  fi
  if ! (cd "$dir" && makepkg --printsrcinfo) >"$tmp"; then
    echo "error: cannot generate .SRCINFO: $dir" >&2
    failed=1
    continue
  fi
  if ! diff -u "$dir/.SRCINFO" "$tmp"; then
    echo "error: stale .SRCINFO: $dir" >&2
    failed=1
  fi
done
exit "$failed"
