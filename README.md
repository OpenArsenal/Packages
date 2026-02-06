Multi-package Arch Linux repository with automated builds and GitHub Pages distribution.

This repo provides:

* Reproducible package builds
* Repo-local build + cache isolation
* Automated CI builds + hosting
* Upstream signature verification

---

# Development

## Prerequisites

```bash
sudo pacman -S --needed base-devel git curl gnupg pacman-contrib direnv
```

Enable direnv in your shell if not already:

```bash
direnv allow
```

---

## Local Testing

Build a package:

```bash
./scripts/build-local.sh package-name
```

Build + install:

```bash
./scripts/build-local.sh 1password -sci
```

---

## Adding Packages

```bash
./scripts/add-package.sh my-package
# edit PKGBUILD
./scripts/build-local.sh my-package
```

---

## Updating Packages

```bash
./scripts/update-package.sh 1password 8.11.5
./scripts/build-local.sh 1password
```

---

# Repository Environment

This repo uses a **repo-local makepkg environment** loaded via `direnv`.

Key exported paths:

* `PKGDEST` → built packages
* `SRCDEST` → downloaded sources
* `BUILDDIR` → working build dirs
* `LOGDEST` → build logs
* `SRCPKGDEST` → source packages
* `GNUPGHOME` → repo-local GPG keyring

Confirm:

```bash
echo $GNUPGHOME
```

---

# Repo-Local GPG Keyring

## Why this exists

We isolate GPG operations so builds are:

* Reproducible
* Independent of maintainer keyrings
* CI-compatible
* Auditable via `validpgpkeys`

Because of this, the repo keyring is **git-ignored**:

```
.gnupg/
```

Every contributor must bootstrap it locally.

---

## Initializing the keyring

Run once per clone:

```bash
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

gpg --homedir "$GNUPGHOME" --list-keys >/dev/null
```

---

# Upstream Signature Verification

Some PKGBUILDs verify upstream artifacts in `check()`.

If a key is missing, builds fail with:

```
gpg: Can't check signature: No public key
==> ERROR: A failure occurred in check().
```

This means the signing key is not in the repo keyring.

---

## Importing Signing Keys

### Example — 1Password CLI

Fingerprint:

```
3FEF 9748 469A DBE1 5DA7  CA80 AC2D 6274 2012 EA22
```

### Import via keyserver

**Bash/zsh**

```bash
KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
gpg --homedir "$GNUPGHOME" --keyserver keyserver.ubuntu.com --recv-keys "$KEY"
```

**Fish**

```fish
set KEY 3FEF9748469ADBE15DA7CA80AC2D62742012EA22
gpg --homedir "$GNUPGHOME" --keyserver keyserver.ubuntu.com --recv-keys $KEY
```

---

## Trusting Keys (optional)

Without trust you may see:

```
WARNING: This key is not certified with a trusted signature!
```

The signature is still valid — this is only a Web-of-Trust warning.

To suppress it:

```bash
gpg --homedir "$GNUPGHOME" --edit-key 3FEF9748469ADBE15DA7CA80AC2D62742012EA22
trust
# choose 4 or 5
quit
```

Rebuild trustdb:

```bash
gpg --homedir "$GNUPGHOME" --check-trustdb
```

---

## Verify key presence

```bash
gpg --homedir "$GNUPGHOME" --list-keys
```

---

# Building Packages

```bash
makepkg -Cfsri
```

Artifacts output to:

```
repo/x86_64/
```

## Local repo permissions (pacman `DownloadUser`)

When you add this repo to `pacman.conf` using a `file://...` URL, **pacman does not necessarily read the DB as root**.
On modern Arch/pacman setups, downloads are performed by an unprivileged user (commonly `alpm`) via `DownloadUser`.
If your repository lives under `/home/<you>/...` and your home directory is `0700` (common default),
`alpm` cannot traverse the path, and you’ll see errors like:

```

openarsenal.db failed to download
error: failed retrieving file 'openarsenal.db' from disk : Could not open file /home/<you>/.../openarsenal.db

```

### Fix (ACL) — allow `alpm` to traverse + read the repo

Run once (adjust the path if your repo lives elsewhere):

```bash
# Allow alpm to traverse the path (execute bit on directories)
sudo setfacl -m u:alpm:--x /home/$USER
sudo setfacl -m u:alpm:--x /home/$USER/Projects
sudo setfacl -m u:alpm:--x /home/$USER/Projects/Packages
sudo setfacl -m u:alpm:--x /home/$USER/Projects/Packages/repo
sudo setfacl -m u:alpm:--x /home/$USER/Projects/Packages/repo/x86_64

# Allow alpm to read repo contents (DB + packages)
sudo setfacl -m u:alpm:r-- /home/$USER/Projects/Packages/repo/x86_64/openarsenal.db*
sudo setfacl -m u:alpm:r-- /home/$USER/Projects/Packages/repo/x86_64/*.pkg.tar.*
```

To ensure **future** DB/package files are readable without re-running ACLs every time:

```bash
sudo setfacl -m d:u:alpm:rx /home/$USER/Projects/Packages/repo/x86_64
```

Verify:

```bash
sudo -u alpm ls -l /home/$USER/Projects/Packages/repo/x86_64/
sudo pacman -Sy
```

---

# Automation

## GitHub Actions

Features:

* Auto-build on changes
* Parallel package builds
* GitHub Pages repo hosting
* Manual workflow triggers
* Weekly rebuilds
* Signature verification
* Artifact uploads

---

## Manual CI Trigger

1. Actions → **Build All Packages**
2. Run workflow
3. Select packages or `all`

---

# Repository Structure

```
.
├── 1password/
│   ├── PKGBUILD
│   └── 1password.install
├── another-package/
│   └── PKGBUILD
└── yet-another/
    └── PKGBUILD
```

---

# Packaging Guidelines

* Runtime deps → `depends=()`
* Build deps → `makedepends=()`
* Optional → `optdepends=()`
* AUR deps allowed
* Add `validpgpkeys=()` for signed sources
* Bump `pkgrel` for packaging-only changes

---

# Update Workflow

1. Detect upstream release
2. Update locally
3. Test build
4. Commit + push
5. CI builds + deploys

---

# Troubleshooting

## Build failures

* Check CI logs
* Rebuild locally
* Verify sources + sums

## GPG failures

* Import missing keys
* Verify fingerprints
* Ensure `$GNUPGHOME` is initialized

## Repo access issues

* Confirm Pages enabled
* Check pacman.conf URL
* Adjust SigLevel if needed

---

# License

Repo structure: MIT
Packages retain upstream licenses.
