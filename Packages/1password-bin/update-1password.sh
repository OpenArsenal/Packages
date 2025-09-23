#!/bin/bash
# update-1password.sh
NEW_VER="$1"
[[ -z "$NEW_VER" ]] && { echo "Usage: $0 <version>"; exit 1; }

cd ~/pkgbuilds/1password
sed -i "s/^_tarver=.*/_tarver=${NEW_VER}/" PKGBUILD
updpkgsums
makepkg -c