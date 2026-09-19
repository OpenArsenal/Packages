# OpenArsenal Packages

Arch/CachyOS package sources and local repository tooling for OpenArsenal.

The package source tree lives under `packages/`. Built packages are published to a system repository outside the Git checkout.

## Repository layout

The default production layout is:

```text
/srv/pacman/repos/openarsenal/
└── x86_64_v3/
    ├── openarsenal.db
    ├── openarsenal.db.tar.zst
    ├── openarsenal.files
    ├── openarsenal.files.tar.zst
    └── *.pkg.tar.zst
```

There is intentionally no `repo/` directory inside this Git repository.

## Environment

Copy the example file once per checkout:

```sh
cp .env.example .env
```

`.env` is ignored by Git and loaded by mise. The defaults in `.mise/config.toml` already match the production layout, so only machine-specific overrides need to be added.

Important variables:

```text
REPO_NAME=openarsenal
REPO_BASE=/srv/pacman/repos/openarsenal
REPO_ARCH=x86_64_v3
REPO_DIR=$REPO_BASE/$REPO_ARCH
REPO_DB=$REPO_DIR/openarsenal.db.tar.zst
PKGDEST=$REPO_DIR
CHROOT_BASE=/var/lib/archbuild
CHROOT_DIR=$CHROOT_BASE/openarsenal-x86_64_v3
```

## Prerequisites

The workflow expects Arch packaging/devtools commands, including `makepkg`, `pkgctl`, `mkarchroot`, `makechrootpkg`, `repo-add`, `repo-remove`, `paccache`, and `nvchecker`.

Check the host before building:

```sh
mise run doctor
```

## Pacman repository configuration

Print the stanza for the configured repository:

```sh
mise run repo:config
```

With the default environment it resolves to:

```ini
[openarsenal]
SigLevel = Optional TrustAll
Server = file:///srv/pacman/repos/openarsenal/x86_64_v3
```

The same path is made visible to clean build chroots when local repository dependencies are needed.

## Clean chroot

Provision or update the clean package-build chroot:

```sh
mise run chroot:create
mise run chroot:update
```

Destroying the chroot is safe because it is disposable build state:

```sh
mise run chroot:destroy
```

The published package repository is persistent state and deliberately has no corresponding `repo:destroy` task.

## Building packages

Show the local dependency/build order:

```sh
mise run pkg:plan <package>
```

Build one package plus any local dependencies that are not already satisfied:

```sh
mise run pkg:build <package>
```

Build the packages listed in `.packages`:

```sh
mise run pkg:build-selected
```

Builds use `PKGDEST=$REPO_DIR`. Successful outputs are added to `openarsenal.db.tar.zst` immediately.

## Package updates

Package-local `.nvchecker.toml` files are the source of truth for version checks. There is no separate feed registry or generator.

Check all nvchecker-enabled packages:

```sh
mise run pkg:update
```

Check one package:

```sh
mise run pkg:update <package>
```

Apply detected updates and refresh `.SRCINFO`:

```sh
mise run pkg:update --apply <package>
```

## Repository database maintenance

### Add/update package archives

`repo:update` selects the newest archive for each package and updates the repository database:

```sh
mise run repo:update
```

It can also target one package/archive/glob:

```sh
mise run repo:update <package>
```

### Remove stale database entries

Deleting a package directory from Git does not automatically remove its old entry from a pacman repository database.

Preview entries present in the DB but no longer produced by any `packages/*/PKGBUILD`:

```sh
mise run repo:clean --dry-run
```

Remove those stale entries:

```sh
mise run repo:clean
```

Remove them and refresh the host pacman sync DB:

```sh
mise run repo:clean --refresh-sync
```

This uses `repo-remove`; it does not rebuild the database from scratch.

### Prune archives

Preview package archives that are no longer indexed plus old retained versions:

```sh
mise run repo:prune --dry-run
```

Prune them, keeping two indexed versions per package by default:

```sh
mise run repo:prune
```

Change the retained version count when needed:

```sh
mise run repo:prune --keep 1
```

### Full maintenance

Run update, DB reconciliation, then archive pruning:

```sh
mise run repo:maintain
```

## Package selection

Populate `.packages` from packages currently installed from the configured OpenArsenal repository:

```sh
mise run pkg:select-installed
```

Use `pkg:plan` before a larger build to inspect the dependency order without changing the chroot or repository.

## Design rules

- `packages/` is the only package-source root.
- `/srv/pacman/repos/openarsenal/x86_64_v3` is the default published repository.
- `/var/lib/archbuild/openarsenal-x86_64_v3` is disposable clean-chroot state.
- `.env` contains machine-local overrides; `.env.example` documents supported defaults.
- Package-local `.nvchecker.toml` files are authoritative for update checks.
- The repository is maintained locally; there is no GitHub Actions package publisher.
