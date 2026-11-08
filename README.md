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
sudo pacman -S --needed base-devel devtools git gnupg jq mise nvchecker pacman-contrib
mise trust
mise run doctor
```

## Repository environment

`mise.toml` defines defaults, `.env.repo` provides shared settings, and the
ignored `.env` holds local overrides and credentials. Tasks load this environment
automatically.

Key paths:

* `PKG_DIR` → package recipes
* `REPO_DIR` → local pacman repository
* `PKGDEST` → built packages (defaults to `REPO_DIR`)
* `CHROOT_DIR` → build chroot directory containing `root/`
* `GNUPGHOME` → repo-local GPG keyring

Repository, package, and chroot paths can be overridden in `.env`.
`GNUPGHOME` stays repo-local to isolate signing keys. Optional makepkg settings
such as `SRCDEST`, `BUILDDIR`, and `LOGDEST` can also be set in `.env`.
`package:build` sets `SOURCE_DATE_EPOCH` from the latest repository commit unless
you supply a value.

## Build setup

```bash
mise run repo:create
mise run chroot:create
```

The chroot uses `/etc/pacman.conf` by default. Set `CHROOT_PACMAN_CONF` in `.env`
to use a different configuration.

Run builds from the desired package directory:

```bash
cd packages/1password-cli-bin
mise run package:build
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

From the desired package directory:

```bash
mise run package:build
```

Artifacts go to `PKGDEST`, which defaults to
`/srv/pacman/repos/openarsenal/x86_64_v3`. The build task does not install them.

After building, update the repository database:

```bash
mise run repo:update --prevent-downgrade
```

## Local repo permissions (pacman `DownloadUser`)

For a `file://` repository, pacman's download user (commonly `alpm`) needs
traversal access to every parent directory and read access to the database and
package files. This is particularly important if you move the repo under a
private home directory.

Check the configured location with:

```bash
mise exec -- printenv REPO_DIR
```

If downloads report permission errors, inspect that path's parent permissions
with `namei -l`, then grant only the necessary traversal/read access. Keep
future files readable through appropriate directory permissions or default ACLs.

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

# Checking Installed Packages

Run `mise run check-installed` (requires Bash, `pacman`, `nvchecker`, `jq`,
`vercmp`, and GNU `timeout`). This is check-only: it does not install/build packages, edit
PKGBUILDs or `.SRCINFO`, or update nvchecker version-state files. Upstream
checks use the network and any credentials required by the local config.

Mise loads shared settings from `.env.repo` and local overrides from the
**git-ignored `.env`**. To authenticate GitHub checks, set `GITHUB_TOKEN` in `.env`.
You can reuse your `gh` login with this one-time setup command from the repo root
(run only if `.env` does not already define `GITHUB_TOKEN`):

```sh
sh -c 'umask 077; token=$(gh auth token --hostname github.com) || exit; printf "\nGITHUB_TOKEN=%s\n" "$token" >> .env'
chmod 600 .env
```

The task does not call `gh` or parse credential stores. When `GITHUB_TOKEN` is
set, it supplies NVChecker a private temporary keyfile containing only the
`github.com` key (overriding configured keyfiles). Explicit per-entry tokens still
take precedence. Without the environment token, NVChecker uses its own keyfile
and netrc handling; use absolute keyfile paths because checks use temporary
configs. Temporary files are removed after use, and the local token is redacted
from diagnostics. Public checks work without a token, but have lower rate limits.

Only installed names from `pacman -Q` that appear as `pkgname` in local
`packages/*/.SRCINFO` are checked, including split packages. The checker reads
`.nvchecker.toml` (preferred) or `nvchecker.toml`. Entries are selected by package
name, then pkgbase, then a sole entry; ambiguous mappings are reported.

Results compare **installed versions against upstream**, not against the local
recipe version. Release comparisons use `vercmp` on pkgver, ignoring the installed
Arch epoch and pkgrel. Numeric upstream `v` prefixes are normalized. For NCCL,
the upstream tag revision is excluded, matching the recipe’s separate
`_upstr_pkgrel` (revision-only updates cannot be detected from installed pkgver).
Git sources without commit checking can also return comparable release tags.
Unrecognized release formats are `unknown`. Git configs
with `use_commit = true` compare the full upstream hash against an installed
`.g<short hash>` or `+<short hash>` suffix (as generated by ntfsplus), or raw hash. A mismatch is `different-commit`, not a claim
that the installed commit is older (ancestry is not checked).

The final report groups `outdated`, `different-commit`, and `newer` packages into
installed -> upstream rows, abbreviating long hashes to 12 characters. Current
packages are counted without individual rows. Missing configs appear in a skipped
list; failed checks (including config errors and unreachable upstreams) and
`unknown` comparisons appear separately under warnings with concise reasons, never
as current. Progress uses a single transient line on interactive stderr only;
redirected/non-TTY output contains only the final report. Each upstream check has
a 30-second timeout, with subprocess-group cleanup on timeout.

By default, per-package warnings return exit status 0 so an unreachable upstream
does not fail the whole task. Use `mise run check-installed --strict` to return 1
if any check failed or is unknown. Inability to enumerate installed packages is
always fatal (exit 1). Skipped, outdated, newer, and different-commit results do
not themselves cause a nonzero exit, even in strict mode. “Newer” describes only
the configured upstream result, not proof that its release channel is correct.
No remediation is performed.

## Other mise tasks

- `mise run aur:import <package-or-url>...` imports packaging into `packages/`,
  preserving upstream `.nvchecker.toml` files. It tries AUR, then Arch packaging;
  use `--source aur` or `--source archlinux` to select one. Existing directories
  require `--force` and are replaced only after a successful clone containing
  `PKGBUILD`.
- Run `mise run package:build` from the directory containing the desired
  `PKGBUILD`. This builds in the configured chroot but does not install it.
- `mise run repo:update` adds the newest local archive for each package to the
  configured repository database, ignoring detached signature files.
- `mise run cleanup` previews ignored files under `packages/` and `.cache/`.
  Add `--force` to delete them. Credentials, signing keys, and untracked recipes
  outside that ignored-artifact scope are preserved.
- `mise run chroot:delete --force` explicitly confirms chroot deletion.
- `mise run doctor` checks the tools needed by the tasks.

All mise task files are Bash scripts. Use `check-installed` to inspect versions,
then review and update recipes before building. The intentionally pinned
ONNX Runtime CUDA 12 recipe stays pinned.

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
