#!/bin/bash

# This script updates the package version if a new version is available
set -euxo pipefail

# Pull latest changes
git pull

# Get channel
CHANNEL=$(awk -F '=' '/^_channel/{ print $2 }' PKGBUILD)
PKG="microsoft-edge-${CHANNEL}"

# xmllint's string() XPath expression succeeds with an empty result when
# metadata fields are missing. Check every value before editing PKGBUILD.
[[ "$CHANNEL" =~ ^[a-z][a-z0-9-]*$ ]] || {
    echo "error: invalid or missing Edge channel in PKGBUILD" >&2
    exit 1
}

#Get filelists URL
FILELISTS=$(curl -sSf "https://packages.microsoft.com/yumrepos/edge/repodata/repomd.xml" |
    xmllint --xpath 'string(//*[local-name()="data"][@type="filelists"]/*[local-name()="location"]/@href)' -)

[[ "$FILELISTS" =~ ^repodata/[A-Za-z0-9._-]+$ ]] || {
    echo "error: missing or invalid Edge filelists metadata path" >&2
    exit 1
}

# Get latest version
VER=$(curl -sSf "https://packages.microsoft.com/yumrepos/edge/${FILELISTS}" |
    gzip -dc |
    xmllint --xpath 'string(//*[local-name()="package"][@name="microsoft-edge-stable"][last()]/*[local-name()="version"]/@ver)' -)

[[ "$VER" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || {
    echo "error: missing or invalid Edge version in filelists metadata" >&2
    exit 1
}

# updpkgsums
SUM256=$(curl -sSf "https://packages.microsoft.com/yumrepos/edge/${FILELISTS}" |
    gzip -dc |
    xmllint --xpath 'string(//*[local-name()="package"][@name="microsoft-edge-stable"][last()]/@pkgid)' -)

[[ "$SUM256" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "error: missing or invalid Edge SHA-256 checksum in filelists metadata" >&2
    exit 1
}

# Insert latest version into PKGBUILD and update hashes
sed -i \
    -e "s/^pkgver=.*/pkgver=${VER}/" \
    PKGBUILD

# Check whether this changed anything
if (git diff --exit-code PKGBUILD); then
    echo "Package ${PKG} has most recent version ${VER}"
    exit 0
fi

# Insert latest shasum into PKGBUILD and update hashes
sed -i \
    -e "s/^sha256sums=('.*/sha256sums=('${SUM256}'/" \
    PKGBUILD

# Reset pkgrel
sed -i \
    -e 's/pkgrel=.*/pkgrel=1/' \
    PKGBUILD

# Preparing arch-chroot
CHROOT=$HOME/.local/share/chroot
if [[ ! -d "$CHROOT" ]]; then
    mkdir -p ~/.local/share/chroot
    mkarchroot $HOME/.local/share/chroot/root base-devel
    arch-nspawn $HOME/.local/share/chroot/root pacman -Syu
fi

# Start generate package
makechrootpkg -c -r $CHROOT -- -Acsf .

# Update .SRCINFO
makepkg --printsrcinfo >.SRCINFO

# Commit changes
git add PKGBUILD .SRCINFO
git commit -s -m "Update ${PKG} to v${VER}"
rm -rf *.deb *.rpm *.log *.zst
