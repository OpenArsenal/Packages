#!/usr/bin/env bash

set -euo pipefail

makepkg -ofC

# Read every value used by PKGBUILD before changing the recipe. In particular,
# a readonly declaration with command substitution masks the command's status.
ENGINE_VERSION="$(cat src/flutter/bin/internal/engine.version)" || {
  echo "error: unable to read Flutter engine version" >&2
  exit 1
}
MATERIAL_FONTS_VERSION="$(cat src/flutter/bin/internal/material_fonts.version | cut -d '/' -f4)" || {
  echo "error: unable to read material fonts version" >&2
  exit 1
}
GRADLE_WRAPPER_VERSION="$(cat src/flutter/bin/internal/gradle_wrapper.version | cut -d '/' -f3)" || {
  echo "error: unable to read Gradle wrapper version" >&2
  exit 1
}
SDK_VERSION="$(cat src/dart/dart-sdk/version)" || {
  echo "error: unable to read Dart SDK version" >&2
  exit 1
}

for name in ENGINE_VERSION MATERIAL_FONTS_VERSION GRADLE_WRAPPER_VERSION SDK_VERSION; do
  value="${!name}"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    echo "error: missing or empty artifact version: $name" >&2
    exit 1
  fi
done

readonly ENGINE_VERSION MATERIAL_FONTS_VERSION GRADLE_WRAPPER_VERSION SDK_VERSION

sed -i \
  -e 's/_dartver=.*/_dartver="'"$SDK_VERSION"'"/g' \
  -e 's/_enginever=.*/_enginever='"$ENGINE_VERSION"'/g' \
  -e 's/_materialfontsver=.*/_materialfontsver='"$MATERIAL_FONTS_VERSION"'/g' \
  -e 's/_gradlewver=.*/_gradlewver='"$GRADLE_WRAPPER_VERSION"'/g' \
  PKGBUILD
