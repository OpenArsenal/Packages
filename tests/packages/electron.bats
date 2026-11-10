#!/usr/bin/env bats
# electron package-specific Bats regression suite.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

@test "Electron package aliases match their declared versions" {
  (
  local major dir actual metadata
  for major in 40 41; do
    (
      dir="$root/packages/electron${major}-castlab-bin"
      source "$dir/PKGBUILD"
      actual="$(printf '%s\n' "${provides[@]}" | LC_ALL=C sort)"
      metadata="$(sed -n 's/^[[:space:]]*provides = //p' "$dir/.SRCINFO" | LC_ALL=C sort)"
      [[ "$(sed -n 's/^[[:space:]]*pkgrel = //p' "$dir/.SRCINFO")" == "$pkgrel" ]] || fail "electron $major metadata pkgrel mismatch"
      [[ "$(sed -n 's/^[[:space:]]*pkgver = //p' "$dir/.SRCINFO")" == "$pkgver" ]] || fail "electron $major metadata pkgver mismatch"
      [[ "$actual" == "$metadata" ]] || fail "electron $major .SRCINFO does not match PKGBUILD"
      [[ "$actual" != *electron42-castlab* ]] || fail "electron $major incorrectly provides Electron 42"
      [[ "$actual" == *"electron-castlab=$pkgver"* ]] || fail "electron $major lost generic alias"
      if [[ "$major" == 40 ]]; then
        [[ ${#provides[@]} -eq 1 ]] || fail 'Electron 40 has extra provides aliases'
      else
        [[ ${#provides[@]} -eq 2 && "$actual" == *"electron41-castlab=$pkgver"* ]] || fail 'Electron 41 missing correct versioned alias'
      fi
    )
  done
  echo 'PASS electron aliases (correct runtime, updated release, .SRCINFO agrees)'
  )
}
