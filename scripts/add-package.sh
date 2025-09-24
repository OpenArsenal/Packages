#!/bin/bash
# Add new package to repository

set -e
source "$(dirname "$0")/../.config"

PACKAGE_NAME="$1"
if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package-name>"
    echo "Example: $0 my-awesome-package"
    exit 1
fi

PACKAGE_DIR="packages/archlinux/$PACKAGE_NAME"

# Create package directory
mkdir -p "$PACKAGE_DIR"
cd "$PACKAGE_DIR"

# Create template PKGBUILD
cat > PKGBUILD << PKGEOF
# Maintainer: $MAINTAINER_NAME <$MAINTAINER_EMAIL>

pkgname=$PACKAGE_NAME
pkgver=1.0.0
pkgrel=1
pkgdesc="Description of $PACKAGE_NAME"
arch=('x86_64')
url="https://example.com"
license=('MIT')
depends=()
makedepends=()
optdepends=()
source=()
sha256sums=()

build() {
    cd "\$srcdir"
    # Build commands here
}

package() {
    cd "\$srcdir"
    # Installation commands here
}
PKGEOF

echo "✅ Created package template: $PACKAGE_DIR/PKGBUILD"
echo "📝 Edit the PKGBUILD file and run: scripts/build-local.sh $PACKAGE_NAME"
