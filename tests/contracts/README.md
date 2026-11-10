# Package contracts

This directory establishes **shared expectations**, not a common implementation
for every PKGBUILD. Tests are split by the lowest useful level:

| Layer | Scope | Direct command from repository root |
| --- | --- | --- |
| Universal | Every recipe: .SRCINFO fields, PKGBUILD/install-hook Bash syntax, declared install files and local-source hashes | `python3 tests/contracts/check.py universal` |
| Capability | Configured launcher families: flags from XDG paths containing spaces, equals-style flags, CLI arguments, and comments | `python3 tests/contracts/check.py launchers` |
| Manifest | All `*-flags-wrapper.sh` and known update scripts are registered; mapped updater and hook regressions still exist | `python3 tests/contracts/check.py registry` |
| Specific | Mock-backed updater, install-hook, source ordering and restoration behavior that cannot safely be inferred from file names | `bats tests/packages` |

Run the package testing tasks from the top-level `packages/` directory:

```sh
cd packages
mise run test:contracts     # Contract harness unit tests + universal/capability checks
mise run test:regressions   # All specialized package Bats tests
mise run test               # Both package groups
```

The sole package `mise.toml` is `packages/mise.toml`; its tasks also apply
in package subdirectories. From the **repository root**, `mise run test` runs
only shared Bats tests, while `mise run test:all` explicitly runs the shared
and package-root test groups. CI runs shared tooling separately from the
package-root `mise run test` entrypoint, which runs both contracts and
regressions once.

The existing `tests/check-local-source-checksums.py` is **reused**, not
reimplemented: it validates source files against `.SRCINFO` checksums and
checks that declared `.install` files exist. `tests/check-srcinfo.sh` remains
the stronger Arch-only `makepkg --printsrcinfo` comparison for environments
where `makepkg` is available. Universal checks don't download sources, verify
remote archives, or attempt package installation.

## Adding a package

1. Add the PKGBUILD and generated `.SRCINFO`. It automatically receives
   universal metadata, syntax and local-source validation.
2. If it ships a `*-flags-wrapper.sh`, add it to an existing `[[launchers]]`
   family in `capabilities.toml`, or add a new family. CI deliberately rejects
   unregistered wrapper files. Configured wrappers are actually executed with
   a fake application; `XDG_CONFIG_HOME` contains spaces and each declared
   config supplies an equals-style flag.
3. If it ships an `update*.sh` or `package-update.sh`, add an
   `updater-fail-closed` behavior record linking its entrypoint to a Bats
   regression that proves failures leave the recipe unchanged. The manifest
   check fails if an updater is unregistered or a linked test disappears.
4. When an install hook changes/removes other files, add a focused
   `install-hook-preserves-user-data` or `install-hook-lifecycle` behavior
   and a mocked Bats regression. All install scripts get universal existence
   and syntax checks; **those alone do not prove they are non-destructive**.
5. Keep genuinely unique behavior (such as Electron source tree ordering) in
   `tests/packages/`. Avoid copying a common contract into many package files.

### Launcher adapters

Each `[[launchers]]` declaration supplies the package directories, source
script, relative XDG config paths, and one narrow adapter:

- `token` replaces a packaging-time executable placeholder.
- `literal` replaces a hardcoded executable with the fixture executable.
- `electron` replaces an Electron binary and application token, and may
  redirect a hardcoded application directory.
- `figma`, `snap`, and `cherry-bin` redirect application directories and
  supply a fake executable there.

The runner requires all configuration and CLI flags to arrive exactly once.
It also checks config comments are not forwarded and, where declared, that
environment assignments survive. All paths, fake binaries, HOME, data and
state directories are temporary. No GUI, root operations, Arch tools, or
network access is required.

**Limitations:** Generic adapters don't prove that every shell updater is
atomic, that every install hook is safe, or that all dependency staging is
ordered correctly. Those are behavioral requirements handled by the
explicitly mapped package regressions. Adding unrelated static grep rules
would create false confidence rather than meaningful coverage.
