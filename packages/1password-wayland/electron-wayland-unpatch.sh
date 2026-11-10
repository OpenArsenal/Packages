#!/bin/bash

if [[ ! -e '{{executable}}' ]]; then
  echo >&2 'Not modifying {{target}} because {{executable}} is not installed.'
  exit 0
fi

if [[ ! -L '{{target}}' ]]; then
  echo >&2 'Not modifying {{target}} because it is not a symlink.'
  exit 0
fi

# Do not overwrite a symlink created by the administrator or another app.
# The patch helper creates this exact link when it owns the target.
if [[ "$(readlink -- '{{target}}')" != '{{launcher}}' ]]; then
  echo >&2 'Not modifying {{target}} because it does not point to {{launcher}}.'
  exit 1
fi

# these are just template placeholders
if [[ '{{executable}}' == *'/{{pkgname}}/'* ]]; then
  # Move original executable back into place
  mv -fv '{{executable}}' '{{target}}' || exit 1
  rmdir -pv --ignore-fail-on-non-empty "$(dirname '{{executable}}')"
else
  # Modify symlink so it points to the original executable
  echo >&2 'Restoring original {{target}}'
  ln -fnsv '{{executable}}' '{{target}}'
fi
