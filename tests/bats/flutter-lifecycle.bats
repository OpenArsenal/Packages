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

@test "Flutter launcher resolves regular and symlinked Dart executables and honors DART_ROOT" {
  (
    local tmp mode binary_dir
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/sdk/bin" "$tmp/links" "$tmp/blocked"

    cat >"$tmp/sdk/bin/dart" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$DART_ROOT" >"$TEST_DART_ROOT_FILE"
printf '%s\n' "$@" >"$TEST_DART_ARGS_FILE"
MOCK
    chmod +x "$tmp/sdk/bin/dart"
    ln -s "$tmp/sdk/bin/dart" "$tmp/links/dart"

    cat >"$tmp/blocked/readlink" <<'MOCK'
#!/usr/bin/env bash
exit 71
MOCK
    chmod +x "$tmp/blocked/readlink"

    for mode in regular symlink; do
      case "$mode" in
        regular) binary_dir="$tmp/sdk/bin" ;;
        symlink) binary_dir="$tmp/links" ;;
      esac
      DART_ROOT="" CI=true FLUTTER_TOOL_ARGS="" PATH="$binary_dir:$PATH" \
        TEST_DART_ROOT_FILE="$tmp/result" TEST_DART_ARGS_FILE="$tmp/args" \
        bash "$root/packages/flutter/flutter.sh" --probe >"$tmp/log" 2>&1 ||
        fail "Flutter launcher rejected a $mode Dart executable: $(cat "$tmp/log")"
      [[ "$(cat "$tmp/result")" == "$tmp/sdk" ]] ||
        fail "Flutter launcher derived the wrong SDK root for $mode"
      grep -Fxq -- '--probe' "$tmp/args" ||
        fail "Flutter launcher lost the CLI argument for $mode"
    done

    # A caller-supplied root must bypass Dart symlink resolution altogether.
    DART_ROOT="$tmp/explicit" CI=true FLUTTER_TOOL_ARGS="" \
      PATH="$tmp/blocked:$tmp/links:$PATH" \
      TEST_DART_ROOT_FILE="$tmp/result" TEST_DART_ARGS_FILE="$tmp/args" \
      bash "$root/packages/flutter/flutter.sh" --probe >"$tmp/log" 2>&1 ||
      fail "Flutter launcher ignored a supplied DART_ROOT: $(cat "$tmp/log")"
    [[ "$(cat "$tmp/result")" == "$tmp/explicit" ]] ||
      fail 'Flutter launcher overwrote DART_ROOT'
  )
}

@test "Flutter PKGBUILD resolves Dart for both package functions" {
  (
    local tmp mode
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/sdk/bin" "$tmp/links" "$tmp/blocked"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/sdk/bin/dart"
    chmod +x "$tmp/sdk/bin/dart"
    ln -s "$tmp/sdk/bin/dart" "$tmp/links/dart"
    printf '#!/usr/bin/env bash\nexit 73\n' >"$tmp/blocked/readlink"
    chmod +x "$tmp/blocked/readlink"

    export CARCH=x86_64
    source "$root/packages/flutter/PKGBUILD"

    for mode in regular symlink; do
      unset DART_ROOT
      case "$mode" in
        regular) export PATH="$tmp/sdk/bin:$PATH" ;;
        symlink) export PATH="$tmp/links:$PATH" ;;
      esac
      _flutter_resolve_dart_root ||
        fail "PKGBUILD failed to resolve $mode Dart executable"
      [[ "$DART_ROOT" == "$tmp/sdk" ]] ||
        fail "PKGBUILD computed the wrong Dart root for $mode"
    done

    export PATH="$tmp/blocked:$tmp/links:$PATH"
    DART_ROOT="$tmp/explicit"
    _flutter_resolve_dart_root ||
      fail 'PKGBUILD ignored an explicit Dart SDK root'
    [[ "$DART_ROOT" == "$tmp/explicit" ]] ||
      fail 'PKGBUILD overwrote the explicit Dart SDK root'

    # Both packaging functions now call this shared resolver.
    [[ "$(declare -f prepare)" == *'_flutter_resolve_dart_root || return 1'* ]] ||
      fail 'prepare did not use the Dart root resolver'
    [[ "$(declare -f _package-intellij-patch)" == *'_flutter_resolve_dart_root || return 1'* ]] ||
      fail 'IntelliJ patch package did not use the Dart root resolver'
  )
}
