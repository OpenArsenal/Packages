#!/usr/bin/env bats
# Flutter package lifecycle behavior with isolated filesystem fixtures.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Fresh Flutter installation preserves an existing SDK directory" {
  (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT

    # Replace absolute install paths only in the fixture copy, not in the
    # package hook. The test must never operate on real host SDK paths.
    mkdir -p "$tmp/opt/flutter/packages/flutter_tools" "$tmp/usr/lib/flutter"
    printf 'manually installed SDK\n' >"$tmp/opt/flutter/packages/flutter_tools/local.txt"
    cp "$tmp/opt/flutter/packages/flutter_tools/local.txt" "$tmp/original"

    sed -e "s#/opt/flutter#$tmp/opt/flutter#g" \
        -e "s#/usr/lib/flutter/.git#$tmp/usr/lib/flutter/.git#g" \
      "$root/packages/flutter/flutter-common.install" >"$tmp/install-hook"

    # pacman pre_install receives only the new version on a fresh install.
    bash -c 'source "$1"; pre_install "3.41.6-2"' _ "$tmp/install-hook" >"$tmp/log" 2>&1 ||
      fail "Flutter pre_install failed: $(cat "$tmp/log")"

    [[ -d "$tmp/opt/flutter/packages/flutter_tools" ]] ||
      fail 'existing SDK directory was deleted'
    cmp -s "$tmp/opt/flutter/packages/flutter_tools/local.txt" "$tmp/original" ||
      fail 'existing SDK contents changed during install'
    grep -Fq 'leaving it untouched' "$tmp/log" ||
      fail 'existing Flutter SDK did not produce a migration notice'
    grep -Fq 'back up and move it manually' "$tmp/log" ||
      fail 'migration notice did not explain manual handling'
  )
}
