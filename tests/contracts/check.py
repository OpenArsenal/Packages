#!/usr/bin/env python3
"""Repository-wide package contracts and data-driven launcher smoke checks.

Stdlib-only, no Arch tools, GUI, root privileges, or network required.
Packages with distinct updater/install behavior retain their Bats regression
adapters; the manifest checks that those contracts remain wired up.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = Path(__file__).with_name("capabilities.toml")
ADAPTERS = {"token", "literal", "electron", "figma", "snap", "cherry-bin"}

FAKE_EXECUTABLE = """#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["CONTRACT_CAPTURE"], "w", encoding="utf-8") as output:
    json.dump({
        "argv": sys.argv[1:],
        "contract_env": os.environ.get("CONTRACT_TEST_ENV"),
    }, output)
"""


def read_srcinfo(path: Path) -> dict[str, list[str]]:
    values: dict[str, list[str]] = defaultdict(list)
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.strip().partition(" = ")
        if separator:
            values[key].append(value)
    return values


def validate_metadata(package_dir: Path) -> list[str]:
    """Minimal Arch metadata invariants; avoids assuming all recipes are alike."""
    errors: list[str] = []
    info = package_dir / ".SRCINFO"
    if not info.is_file():
        return [f"{package_dir}: missing .SRCINFO"]

    fields = read_srcinfo(info)
    for name in ("pkgbase", "pkgver", "pkgrel", "pkgname"):
        values = fields.get(name, [])
        if not values or any(not value or any(ch.isspace() for ch in value) for value in values):
            errors.append(f"{info}: missing or invalid {name}")

    releases = fields.get("pkgrel", [])
    if releases and not all(re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value) for value in releases):
        errors.append(f"{info}: invalid pkgrel (expected a positive numeric release)")
    return errors


def universal_contracts(root: Path) -> list[str]:
    directories = sorted((root / "packages").glob("*/PKGBUILD"))
    errors: list[str] = []
    if not directories:
        return [f"{root}: no package recipes found"]

    install_count = 0
    for pkgbuild in directories:
        directory = pkgbuild.parent
        errors.extend(validate_metadata(directory))
        files = [pkgbuild]
        if (directory / ".SRCINFO").is_file():
            metadata = read_srcinfo(directory / ".SRCINFO")
            for name in metadata.get("install", []):
                candidate = directory / name
                if candidate.is_file():
                    files.append(candidate)
                    install_count += 1
        for file in files:
            check = subprocess.run(["bash", "-n", str(file)], capture_output=True, text=True)
            if check.returncode != 0:
                errors.append(f"{file}: invalid Bash syntax: {check.stderr.strip()}")

    # Reuse the existing source/installation-file verifier. Don't duplicate
    # its hashing logic or weaken its validation of split package sources.
    result = subprocess.run(
        [sys.executable, str(root / "tests/check-local-source-checksums.py")],
        cwd=root, capture_output=True, text=True,
    )
    if result.returncode:
        errors.append(result.stderr.strip() or "local source verification failed")
    elif result.stdout.strip():
        print(result.stdout.strip())
    print(f"Universal metadata/Bash contracts: {len(directories)} recipes, {install_count} install hook references.")
    return errors


def require_package(root: Path, package: str, script: str) -> tuple[Path, list[str]]:
    errors: list[str] = []
    if Path(script).name != script or not script or "/" in script:
        return root, [f"{package}: invalid entrypoint name {script!r}"]
    package_dir = root / "packages" / package
    if not package_dir.is_dir() or not (package_dir / "PKGBUILD").is_file():
        errors.append(f"{package}: missing PKGBUILD")
    path = package_dir / script
    if not path.is_file():
        errors.append(f"{path}: missing declared capability entrypoint")
    return path, errors


def validate_registry(root: Path, registry: dict) -> list[str]:
    errors: list[str] = []
    if registry.get("schema") != 1:
        errors.append("contract manifest schema must be 1")
    seen: set[str] = set()
    for group in registry.get("launchers", []):
        family = group.get("family", "<unknown>")
        adapter = group.get("adapter")
        if adapter not in ADAPTERS:
            errors.append(f"{family}: unsupported launcher adapter {adapter!r}")
        if not group.get("configs"):
            errors.append(f"{family}: declare at least one configuration path")
        packages = group.get("packages", [])
        if not packages:
            errors.append(f"{family}: no package directories")
        if adapter in {"token", "electron"} and not group.get("token"):
            errors.append(f"{family}: missing executable token")
        if adapter == "literal" and not group.get("executable"):
            errors.append(f"{family}: missing executable path")
        for pkg in packages:
            path, problems = require_package(root, pkg, group.get("script", ""))
            errors.extend(problems)
            rel = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
            if rel in seen:
                errors.append(f"{rel}: launcher declared twice")
            seen.add(rel)

    # A new *-flags-wrapper.sh should not silently miss standard tests.
    discovered = {
        str(path.relative_to(root))
        for path in (root / "packages").glob("*/*-flags-wrapper.sh")
    }
    for missing in sorted(discovered - seen):
        errors.append(f"{missing}: missing launcher contract (add a manifest adapter)")
    for stale in sorted(seen - discovered):
        if stale.endswith("-flags-wrapper.sh"):
            errors.append(f"{stale}: stale launcher contract")

    updater_paths: set[str] = set()
    for spec in registry.get("behaviors", []):
        kind = spec.get("capability")
        if kind not in {"updater-fail-closed", "install-hook-preserves-user-data", "install-hook-lifecycle"}:
            errors.append(f"unsupported behavioral contract: {kind!r}")
        suite = root / spec.get("suite", "")
        if not suite.is_file():
            errors.append(f"{suite}: missing referenced Bats suite")
            suite_text = ""
        else:
            suite_text = suite.read_text(encoding="utf-8")
        tests = spec.get("tests", [])
        if not tests:
            errors.append(f"{kind}: no behavioral test names")
        for name in tests:
            if f'@test "{name}"' not in suite_text:
                errors.append(f"{suite}: missing declared Bats regression: {name}")
        for pkg in spec.get("packages", []):
            for entry in spec.get("entrypoints", []):
                path, problems = require_package(root, pkg, entry)
                errors.extend(problems)
                if kind == "updater-fail-closed" and not problems:
                    updater_paths.add(str(path.relative_to(root)))

    # Every updater script needs an explicit fail-closed regression adapter.
    discovered_updaters = {
        str(p.relative_to(root))
        for p in (root / "packages").glob("*/*")
        if p.is_file() and (p.name.startswith("update") and p.suffix == ".sh"
                            or p.name == "package-update.sh")
    }
    for missing in sorted(discovered_updaters - updater_paths):
        errors.append(f"{missing}: missing updater fail-closed contract")
    return errors


def replace_once(text: str, needle: str, new: str, label: str) -> str:
    if not needle or needle not in text:
        raise ValueError(f"{label}: expected launcher substitution {needle!r} not found")
    return text.replace(needle, new)


def launcher_contract(root: Path, spec: dict, package: str) -> list[str]:
    """Run real launch script with isolated XDG config and a fake executable."""
    source = root / "packages" / package / spec["script"]
    with tempfile.TemporaryDirectory(prefix="launcher-contract-") as folder:
        base = Path(folder)
        fake = base / "fake-app"
        fake.write_text(FAKE_EXECUTABLE, encoding="utf-8")
        fake.chmod(0o755)
        appdir = base / "app"
        appdir.mkdir()
        original = source.read_text(encoding="utf-8")
        adapter = spec["adapter"]
        if adapter == "token":
            script = replace_once(original, spec["token"], str(fake), package)
        elif adapter == "literal":
            script = replace_once(original, spec["executable"], str(fake), package)
        elif adapter == "electron":
            script = replace_once(original, spec["token"], str(fake), package)
            script = replace_once(script, spec["app_token"], "contract-app.asar", package)
            if "appdir" in spec:
                script = replace_once(script, f'_APPDIR="{spec["appdir"]}"',
                                      f'_APPDIR="{appdir}"', package)
        elif adapter == "figma":
            script = replace_once(original, '_APPDIR="/opt/figma-linux"',
                                  f'_APPDIR="{appdir}"', package)
            (appdir / "figma-linux").symlink_to(fake)
        elif adapter == "snap":
            script = replace_once(original, 'export SNAP="/opt/singularityapp"',
                                  f'export SNAP="{appdir}"', package)
            (appdir / "command.sh").symlink_to(fake)
        elif adapter == "cherry-bin":
            script = replace_once(original, 'appdir="/opt/cherry-studio"',
                                  f'appdir="{appdir}"', package)
            (appdir / "CherryStudio").symlink_to(fake)
        else:
            return [f"{package}: unsupported launcher adapter {adapter}"]

        wrapper = base / "wrapper.sh"
        wrapper.write_text(script, encoding="utf-8")
        capture = base / "result.json"
        xdg = base / "config directory with spaces"
        xdg.mkdir()
        expected_args: list[str] = []
        for idx, rel in enumerate(spec["configs"]):
            config = xdg / rel
            config.parent.mkdir(parents=True, exist_ok=True)
            flag = f"--contract-config-{idx}=value"
            config.write_text(f"# ignored comment\n{flag}\n", encoding="utf-8")
            expected_args.append(flag)
        if spec.get("environment_assignment"):
            with (xdg / spec["configs"][0]).open("a", encoding="utf-8") as file:
                file.write("CONTRACT_TEST_ENV=hello=world\n")

        home = base / "home"
        home.mkdir()
        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(xdg),
            "XDG_DATA_HOME": str(base / "xdg-data"),
            "XDG_STATE_HOME": str(base / "xdg-state"),
            "XDG_SESSION_TYPE": "x11",
            "WAYLAND_DISPLAY": "",
            "CONTRACT_CAPTURE": str(capture),
            "LD_LIBRARY_PATH": "",
            "GSETTINGS_SCHEMA_DIR": "",
        })
        env.pop("CONTRACT_TEST_ENV", None)
        cli = "--contract-cli=value"
        try:
            result = subprocess.run(
                ["bash", str(wrapper), cli], cwd=base, env=env,
                capture_output=True, text=True, timeout=15,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return [f"{package}: unable to launch fixture: {error}"]
        if result.returncode:
            return [f"{package}: launcher exited {result.returncode}: {result.stderr.strip()}"]
        if not capture.is_file():
            return [f"{package}: launcher did not reach fake executable"]
        record = json.loads(capture.read_text(encoding="utf-8"))
        argv = record["argv"]
        errors = [
            f"{package}: lost or duplicated argument {arg!r}: {argv!r}"
            for arg in [*expected_args, cli] if argv.count(arg) != 1
        ]
        if any("# ignored" in arg for arg in argv):
            errors.append(f"{package}: comment was forwarded to executable")
        if spec.get("environment_assignment") and record.get("contract_env") != "hello=world":
            errors.append(f"{package}: configuration environment assignment not exported")
        return errors


def run(root: Path, mode: str, package: str | None = None) -> int:
    registry = tomllib.loads((root / "tests/contracts/capabilities.toml").read_text(encoding="utf-8"))
    errors: list[str] = []
    if mode in ("all", "universal"):
        errors.extend(universal_contracts(root))
    if mode in ("all", "launchers", "registry"):
        errors.extend(validate_registry(root, registry))
    if mode in ("all", "launchers"):
        count = 0
        for spec in registry.get("launchers", []):
            for pkg in spec["packages"]:
                if package and package != pkg:
                    continue
                count += 1
                try:
                    errors.extend(launcher_contract(root, spec, pkg))
                except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                    errors.append(f"{pkg}: launcher contract could not execute: {error}")
        if count == 0:
            errors.append(f"no launchers matched package {package!r}")
        print(f"Launcher contracts: {count} package wrappers checked.")
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        print(f"{len(errors)} contract failure(s)", file=sys.stderr)
        return 1
    print(f"Contract checks passed ({mode}).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", default="all",
                        choices=("all", "universal", "registry", "launchers"))
    parser.add_argument("--package", help="Limit launcher contract execution to this package")
    args = parser.parse_args()
    if args.package and args.mode not in ("all", "launchers"):
        parser.error("--package applies only to launcher checks")
    return run(ROOT, args.mode, args.package)


if __name__ == "__main__":
    sys.exit(main())
