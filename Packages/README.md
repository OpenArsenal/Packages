# OpenArsenal AUR Repository

Multi-package Arch Linux repository with automated builds and GitHub Pages distribution.

## 📦 Available Packages

| Package | Description | Status |
|---------|-------------|--------|
| 1password | Password manager | ✅ Active |
| other-package | Description | ✅ Active |

## 🛠️ Development

### Prerequisites
```bash
sudo pacman -S --needed base-devel git curl gnupg pacman-contrib
```

### Local Testing
```bash
# Build specific package
./scripts/build-local.sh package-name

# Build & Install
./scripts/build-local.sh 1password -sci
```

### Add New Package
```bash
./scripts/add-package.sh my-package
# Edit ./my-package/PKGBUILD
./scripts/build-local.sh my-package
```

### Update Existing Package
```bash
./scripts/update-package.sh 1password 8.11.5
./scripts/build-local.sh 1password
```

## 🤖 Automation

### GitHub Actions Features
- ✅ **Auto-build** on package changes
- ✅ **Parallel builds** for multiple packages  
- ✅ **GitHub Pages** repository hosting
- ✅ **Manual triggers** with package selection
- ✅ **Weekly rebuilds** to catch dependency updates
- ✅ **GPG verification** and security checks
- ✅ **Artifact uploads** for easy downloads

### Manual Triggers
1. Go to Actions → "Build All Packages"
2. Click "Run workflow"
3. Specify packages (or "all") and options

### Repository Structure
```
./
├── 1password/
│   ├── PKGBUILD
│   └── 1password.install
├── another-package/
│   └── PKGBUILD
└── yet-another/
    └── PKGBUILD
```

## 🔧 Configuration

### Package Guidelines
- **Dependencies**: Use `depends=()` for runtime, `makedepends=()` for build-time
- **Optional deps**: Use `optdepends=('package: description')` for optional features
- **AUR deps**: List in depends arrays - CI will auto-install from AUR
- **GPG verification**: Add `validpgpkeys=()` and `.sig` files to source
- **Versioning**: Follow semantic versioning, bump `pkgrel` for packaging changes

## 📋 Optional Dependencies Examples

```bash
optdepends=(
    'cups: printing support'
    'sane: scanner support'  
    'alsa-lib: audio support'
    'nvidia-utils: GPU acceleration (optional)'
)
```

**Note**: Optional dependencies are for runtime features. If your package is built differently based on presence of a dependency, that dependency should be in `depends=()` or `makedepends=()`.

## 🔄 Update Workflow

1. **Detect updates**: Monitor upstream releases
2. **Update locally**: `./scripts/update-package.sh package version`
3. **Test build**: `./scripts/build-local.sh package`  
4. **Commit & push**: Triggers automated CI build
5. **Deploy**: Packages automatically added to repository

## 🆘 Troubleshooting

### Build Failures
- Check logs in GitHub Actions
- Test locally with `./scripts/build-local.sh`
- Verify dependencies and sources

### GPG Issues  
- Ensure `validpgpkeys=()` is correct
- Check key server accessibility
- Use fallback key import in CI

### Repository Access
- Verify GitHub Pages is enabled
- Check repository URL in pacman.conf
- Ensure SigLevel allows unsigned packages

## 📄 License

This repository structure is MIT licensed. Individual packages retain their original licenses.
