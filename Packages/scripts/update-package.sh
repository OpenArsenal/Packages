#!/bin/bash
# Update package version and checksums

set -e

PACKAGE_NAME="$1"
NEW_VERSION="$2"

if [[ -z "$PACKAGE_NAME" || -z "$NEW_VERSION" ]]; then
    echo "Usage: $0 <package-name> <new-version>"
    echo "Example: $0 1password 8.11.5"
    exit 1
fi

PACKAGE_DIR="./$PACKAGE_NAME"

if [[ ! -d "$PACKAGE_DIR" ]]; then
    echo "❌ Package directory not found: $PACKAGE_DIR"
    exit 1
fi

cd "$PACKAGE_DIR"

echo "Updating $PACKAGE_NAME to version $NEW_VERSION..."

# Update version in PKGBUILD
sed -i "s/^pkgver=.*/pkgver=$NEW_VERSION/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD

# Update checksums
echo "Updating checksums..."
updpkgsums

echo "✅ Updated $PACKAGE_NAME to version $NEW_VERSION"
echo "🧪 Run: scripts/build-local.sh $PACKAGE_NAME"
