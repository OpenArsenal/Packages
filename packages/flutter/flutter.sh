#!/usr/bin/env bash
# adapted by lnl from project's repo

# To debug the tool, you can pass the following env to enable debug
# mode and set an observatory port:
# FLUTTER_TOOL_ARGS="$FLUTTER_TOOL_ARGS --enable-asserts --observe=65432"

set -e

# this is required in case people try to run with `aur/dart-sdk-dev` instead of `extra/dart`
if [[ -z "${DART_ROOT:-}" ]]; then
  DART_BINARY="$(command -v dart)" || {
    echo "error: dart executable not found in PATH" >&2
    exit 1
  }
  DART_BINARY="$(readlink -f -- "$DART_BINARY")" || {
    echo "error: unable to resolve dart executable" >&2
    exit 1
  }
  case "$DART_BINARY" in
    */bin/dart)
      DART_ROOT="${DART_BINARY%/bin/dart}"
      ;;
    *)
      echo "error: unexpected Dart executable location: $DART_BINARY" >&2
      exit 1
      ;;
  esac
  [[ -n "$DART_ROOT" ]] || exit 1
fi
export DART_ROOT
export FLUTTER_ROOT="${FLUTTER_ROOT:-/usr/lib/flutter}"

FLUTTER_TOOLS_DIR="$FLUTTER_ROOT/packages/flutter_tools"
SNAPSHOT_PATH="$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"

# Test if running as superuser – but don't warn if running within Docker or CI.
if [ "$(id -u)" = "0" ] && ! [ -f /.dockerenv ] && [ "$CI" != "true" ] && [ "$BOT" != "true" ] && [ "$CONTINUOUS_INTEGRATION" != "true" ]; then
  >&2 echo "   Woah! You appear to be trying to run flutter as root."
  >&2 echo "   We strongly recommend running the flutter tool without superuser privileges."
  >&2 echo "  /"
  >&2 echo "📎"
fi

exec dart --disable-dart-dev --packages="$FLUTTER_TOOLS_DIR/.dart_tool/package_config.json" $FLUTTER_TOOL_ARGS "$SNAPSHOT_PATH" "$@"

