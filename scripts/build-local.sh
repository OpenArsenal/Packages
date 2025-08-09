#!/bin/bash
# Build package locally for testing (quick and dirty)

set -e

PACKAGE_NAME="$1"
shift || true  # Remove first argument, ignore error if no args

if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package-name> [makepkg-flags]"
    echo ""
    echo "Available packages:"
    find packages/alpm -name PKGBUILD -exec dirname {} \; | sed 's|packages/alpm/||' | sort
    echo ""
    echo "Common flags:"
    echo "  -f    Force overwrite existing packages"
    echo "  -s    Install dependencies with pacman"
    echo "  -i    Install package after build"
    echo "  -c    Clean build and src dirs after build"
    echo ""
    echo "For production-like testing: scripts/build-production.sh $PACKAGE_NAME"
    exit 1
fi

PACKAGE_DIR="packages/alpm/$PACKAGE_NAME"

if [[ ! -d "$PACKAGE_DIR" ]]; then
    echo "❌ Package directory not found: $PACKAGE_DIR"
    echo ""
    echo "Available packages:"
    find packages/alpm -name PKGBUILD -exec dirname {} \; | sed 's|packages/alpm/||' | sort
    exit 1
fi

cd "$PACKAGE_DIR"

echo "=== Building $PACKAGE_NAME locally ==="

# Import GPG keys if needed
if grep -q "^validpgpkeys=" PKGBUILD; then
    echo "Importing GPG keys..."
    
    # Extract GPG keys properly using a more robust method
    python3 -c "
import re
with open('PKGBUILD', 'r') as f:
    content = f.read()

# Find validpgpkeys line
match = re.search(r\"validpgpkeys=\(([^)]+)\)\", content)
if match:
    keys_str = match.group(1)
    # Extract individual keys, handling quotes and spaces
    keys = re.findall(r\"['\\\"]([^'\\\"]+)['\\\"]|([0-9A-Fa-f]{40})\", keys_str)
    for key_match in keys:
        key = key_match[0] or key_match[1]
        if key and len(key) >= 8:  # Valid key length
            print(key)
" > .gpg_keys.tmp
    
    if [[ -s .gpg_keys.tmp ]]; then
        while IFS= read -r key; do
            echo "Importing GPG key: $key"
            gpg --keyserver keyserver.ubuntu.com --recv-keys "$key" 2>/dev/null || \
            gpg --keyserver keys.openpgp.org --recv-keys "$key" 2>/dev/null || \
            gpg --keyserver pgp.mit.edu --recv-keys "$key" 2>/dev/null || \
            echo "⚠️  Could not import key $key from keyservers - continuing anyway"
        done < .gpg_keys.tmp
    fi
    rm -f .gpg_keys.tmp
fi

# Check dependencies 
echo "Generating .SRCINFO..."
makepkg --printsrcinfo > .SRCINFO

# Check for missing dependencies
echo "Checking dependencies..."
MISSING_DEPS=""
if grep -q "^depends=" PKGBUILD; then
    while IFS= read -r dep; do
        # Remove version constraints
        clean_dep=$(echo "$dep" | sed 's/[><=].*//')
        if ! pacman -Qi "$clean_dep" >/dev/null 2>&1 && ! pacman -Si "$clean_dep" >/dev/null 2>&1; then
            MISSING_DEPS="$MISSING_DEPS $clean_dep"
        fi
    done < <(grep "^depends=" PKGBUILD | sed "s/depends=(//" | sed "s/)//" | tr "'" "\n" | grep -v "^$" | grep -v "depends")
fi

if [[ -n "$MISSING_DEPS" ]]; then
    echo "⚠️  Potential AUR dependencies detected:$MISSING_DEPS"
    echo "Install them manually or use scripts/build-production.sh for automatic handling"
fi

# Build package with user-provided flags
echo "Building package with flags: $*"
makepkg -sc "$@"

if [[ $? -eq 0 ]]; then
    echo ""
    echo "✅ Package built successfully!"
    PACKAGE_FILE=$(ls *.pkg.tar.zst 2>/dev/null | head -1)
    if [[ -n "$PACKAGE_FILE" ]]; then
        echo "📦 Package: $PACKAGE_FILE"
        if [[ ! "$*" =~ "-i" ]]; then
            echo "📥 Install with: sudo pacman -U $PACKAGE_FILE"
        fi
    fi
else
    echo "❌ Build failed!"
    exit 1
fi