# OpenArsenal Packages

OpenArsenal's Arch Linux and CachyOS package recipes, with tooling to build and maintain a local pacman repository.

This repository keeps package sources under [`packages/`](packages/) and uses [mise](https://mise.jdx.dev/) tasks to plan local dependencies, build packages in a clean chroot, check upstream versions, and maintain the repository database. **Published package archives live outside the Git checkout**; this repository is not a hosted binary mirror or an npm package.

[![Tests](https://github.com/OpenArsenal/Packages/actions/workflows/tests.yml/badge.svg)](https://github.com/OpenArsenal/Packages/actions/workflows/tests.yml)

## Quick start

You need Git and [mise](https://mise.jdx.dev/) installed. These first steps are non-destructive and do not require an Arch host:

```sh
git clone https://github.com/OpenArsenal/Packages.git
cd Packages
mise install
cp .env.example .env
mise run repo:config
```

With the default configuration, the last command prints the pacman repository stanza:

```ini
[openarsenal]
SigLevel = Optional TrustAll
Server = file:///srv/pacman/repos/openarsenal/x86_64_v3
```

`mise install` installs pinned **Bats-core** and **ShellCheck**, and its postinstall hook fetches tagged `bats-support`, `bats-assert`, and `bats-file` into the ignored `.mise/vendor/bats/` directory. mise sets `BATS_LIB_PATH` so tests can use `bats_load_library bats-assert` and `bats_load_library bats-file` (load `bats-support` first). You can rerun `mise run test:install-libs` to restore the helper libraries. The `.env` file is for machine-local overrides and is ignored by Git. Printing the stanza does **not** edit your host's `/etc/pacman.conf`.

To build packages, use an **Arch Linux or CachyOS host** with the Arch packaging toolchain and root access via `sudo` (or a root shell). Check the required commands before building:

```sh
mise run doctor
```

The doctor checks for `makepkg`, `pkgctl`, `mkarchroot`, `makechrootpkg`, `repo-add`, `repo-remove`, `nvchecker`, and other tools used by the workflows. See [`.mise/tasks/doctor`](.mise/tasks/doctor) for the full list.

## Build a package

For example, to inspect and build the existing `arch-mcp` recipe:

```sh
mise run pkg:plan arch-mcp
mise run pkg:build arch-mcp
```

`pkg:plan` shows which local recipes are needed. `pkg:build` provisions the repository directory and clean build chroot if necessary, builds missing local dependencies, and **publishes successful archives immediately** to the configured pacman database. It can require elevated privileges and changes files outside the checkout.

Use `mise run pkg:build arch-mcp --force` to rebuild an already-published version. To build an existing package selection instead, run `mise run pkg:build-selected` (see below).

## Configuration and repository layout

Defaults are defined in [`.mise/config.toml`](.mise/config.toml); copy [`.env.example`](.env.example) to `.env` to override them for your machine.

| Setting | Default | Purpose |
| --- | --- | --- |
| `REPO_NAME` | `openarsenal` | pacman repository name |
| `REPO_BASE` | `/srv/pacman/repos/openarsenal` | Published repository base directory |
| `REPO_ARCH` | `x86_64_v3` | Architecture-specific repository subdirectory |
| `REPO_DIR` | `$REPO_BASE/$REPO_ARCH` | Where archives and database files are stored |
| `REPO_DB` | `$REPO_DIR/openarsenal.db.tar.zst` | pacman repository database |
| `CHROOT_BASE` | `/var/lib/archbuild` | Clean-build chroot parent directory |
| `CHROOT_DIR` | `$CHROOT_BASE/openarsenal-x86_64_v3` | Disposable build chroot |
| `PACKAGES_FILE` | `.packages` at the repository root | Local package selection, ignored by Git |
| `REPO_SIG_LEVEL` | `Optional TrustAll` | Signature policy emitted by `repo:config` |

`PKGDEST` defaults to `REPO_DIR`, so build outputs go straight to the published repository. With the defaults, the repository files live at:

```text
/srv/pacman/repos/openarsenal/x86_64_v3/
├── openarsenal.db.tar.zst
├── openarsenal.files.tar.zst
└── *.pkg.tar.zst
```

The pacman database may also have its normal `.db` and `.files` links. There is intentionally no `repo/` directory in this Git tree.

| In this checkout | Contains |
| --- | --- |
| [`packages/`](packages/) | Per-package `PKGBUILD`, `.SRCINFO`, and optional `.nvchecker.toml`, patches, hooks, or update scripts |
| [`.mise/config.toml`](.mise/config.toml), [`.mise/tasks/`](.mise/tasks/) | Configuration and packaging/maintenance commands |
| [`packages/mise.toml`](packages/mise.toml) | Package-specific test task entrypoints |
| [`tests/bats/`](tests/bats/) | Shared packaging-tool tests |
| [`tests/contracts/`](tests/contracts/) | Universal package checks and registered capability contracts |
| [`tests/packages/`](tests/packages/) | Package-specific Bats regressions |
| [`.github/workflows/tests.yml`](.github/workflows/tests.yml) | CI tests; not a package publisher |

**Signature policy:** `Optional TrustAll` allows packages without trusted signatures. It is the current local-repository default, **not a recommended setting for untrusted third-party repositories**. Review and set `REPO_SIG_LEVEL` to suit your trust model before distributing packages.

## Common maintenance workflows

### Select and build packages

The optional `.packages` file contains one package directory name per line (blank lines and `#` comments are accepted). To generate it from packages installed from the configured OpenArsenal repository:

```sh
mise run pkg:select-installed --dry-run
mise run pkg:select-installed
mise run pkg:build-selected
```

`pkg:select-installed` requires the repository to be configured and available to the host's pacman installation. Check a selection's build order with `mise run pkg:plan` (without a package argument).

### Check upstream updates

Packages with `.nvchecker.toml` can be checked and updated through `pkgctl`:

```sh
mise run pkg:update arch-mcp
mise run pkg:update --apply arch-mcp
```

Without package arguments, `pkg:update` checks entries in `.packages` **if that file selects packages**; otherwise it checks all recipes with `.nvchecker.toml`. `--apply` modifies the recipe and regenerates `.SRCINFO`, so review the resulting diff before committing.

### Maintain the published repository

Preview potentially destructive changes first:

```sh
mise run repo:update --dry-run
mise run repo:clean --dry-run
mise run repo:prune --dry-run
```

- `repo:update` indexes the newest matching package archives.
- `repo:clean` removes database entries no longer produced by a recipe in `packages/`.
- `repo:prune` removes unindexed archives and older versions (retaining two versions per indexed package by default).

Run each task again without `--dry-run` to apply it. `mise run repo:maintain` performs update, database reconciliation, pruning, and a host pacman sync refresh in sequence; it **does modify and remove published data**. The published repository is persistent and has no `repo:destroy` task.

For chroot maintenance, use `mise run chroot:update` to provision/update it. `mise run chroot:destroy` removes **only** the configured disposable build chroot, not the published repository.

Run `mise tasks` to see the full command list, including `aur:import` and `check-installed`.

## Tests and contributions

Tests run at two levels. From the repository root:

```sh
mise run test       # Shared Bats tooling tests
mise run test:all   # Shared tests, then package contracts and regressions
mise run lint:shell # Opt-in ShellCheck for Bash helpers and mise task scripts
```

To run only package-level checks:

```sh
cd packages
mise run test       # Package contracts and specialized regressions
```

The package-level tasks are inherited in package subdirectories; they still run the full package test group. [GitHub Actions](.github/workflows/tests.yml) runs the shared tests and package-level tests in separate jobs. Most tests use fixtures and mocked external tools; **passing CI is not a substitute for an actual package build**.

When contributing a recipe or making a packaging change:

1. Edit or add `packages/<name>/PKGBUILD` and its generated `.SRCINFO`. Add `.nvchecker.toml` when upstream update checks are supported.
2. On an Arch host with `makepkg`, verify metadata with `bash tests/check-srcinfo.sh packages/<name>` (replace `<name>` with the actual directory).
3. Run `mise run test:all`. For wrappers, custom update scripts, or install hooks, add the relevant contract registration and focused regression tests described in the [package contract guide](tests/contracts/README.md).
4. Open a [pull request](https://github.com/OpenArsenal/Packages/pulls) with the change and any relevant build/test notes.

Report packaging or tooling problems in [GitHub Issues](https://github.com/OpenArsenal/Packages/issues).

## Scope and licensing

This repository supplies **packaging sources and local maintenance tools**. It does not publish a binary repository through GitHub Actions; published artifacts are managed at the configured local filesystem path. Building and maintenance operations assume a trusted Arch/CachyOS packaging environment.

There is currently **no top-level repository license file**. Individual `PKGBUILD` `license` declarations describe the packaged upstream software and should not be taken as a license for this repository's own files.
