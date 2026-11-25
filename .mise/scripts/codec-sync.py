#!/usr/bin/env python3
"""Synchronize a Chromium codec recipe using its own nvchecker configuration.

Explicit-version updater commands remain available for manual overrides. This
entry point stages a complete latest-version update and never publishes partial
metadata or silently downgrades a browser or FFmpeg component.
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CHROME = {"google-chrome-ffmpeg", "google-chrome-canary-ffmpeg"}
COMPOSITE = {"chromium-ffmpeg", "vivaldi-ffmpeg"}
BROWSER_VERSION = r"[0-9]+(?:\.[0-9]+){3}"
FFMPEG_VERSION = r"[0-9]+(?:\.[0-9]+){1,2}"


def run(args, *, cwd=None, env=None, capture=False):
    return subprocess.run(args, cwd=cwd, env=env, text=True, check=True,
                          stdout=subprocess.PIPE if capture else None)


def field(recipe, name):
    matches = re.findall(r"^" + re.escape(name) + r"=([^\n]+)$",
                         recipe.read_text(), re.M)
    if len(matches) != 1:
        raise ValueError(f"expected one {name} assignment in {recipe}")
    return matches[0]


def set_field(recipe, name, value):
    field(recipe, name)
    recipe.write_text(re.sub(r"^" + re.escape(name) + r"=[^\n]+$",
                             f"{name}={value}", recipe.read_text(),
                             flags=re.M))


def validate(version, pattern, label):
    if not isinstance(version, str) or not re.fullmatch(pattern, version):
        raise ValueError(f"invalid {label} version: {version!r}")
    return version


def compare(new, old, label):
    order = run(["vercmp", new, old], capture=True).stdout.strip()
    if order not in {"-1", "0", "1"}:
        raise ValueError(f"invalid vercmp result for {label}")
    if order == "-1":
        raise ValueError(f"refusing to downgrade {label}: {old} -> {new}")
    return int(order)


def latest(directory, names):
    # Same configuration and keyfile convention as pkgctl. Only accept
    # successful, unambiguous results for the requested entries.
    config = directory / ".nvchecker.toml"
    args = ["nvchecker", "--file", str(config), "--logger", "json"]
    keyfile = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "nvchecker/keyfile.toml"
    if keyfile.is_file():
        args += ["--keyfile", str(keyfile)]
    result = subprocess.run(args, cwd=directory, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            check=False, timeout=120)
    if result.returncode:
        raise ValueError(f"nvchecker failed (exit {result.returncode}); no files changed")
    versions = {}
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("level") == "error":
            raise ValueError("nvchecker reported an upstream error; no files changed")
        name = event.get("name")
        if name in names and event.get("event") in {"updated", "up-to-date"}:
            version = event.get("version")
            if name in versions and versions[name] != version:
                raise ValueError(f"conflicting nvchecker results for {name}")
            versions[name] = version
    if set(versions) != set(names):
        raise ValueError("missing nvchecker results: " + ", ".join(sorted(set(names) - versions.keys())))
    return versions


def metadata(text, key):
    matches = re.findall(r"^\s*" + re.escape(key) + r" = (\S+)\s*$", text, re.M)
    if len(matches) != 1:
        raise ValueError(f"invalid generated .SRCINFO ({key})")
    return matches[0]


def install_pair(directory, recipe, info, original):
    # Prepare replacements on the destination filesystem. Check for concurrent
    # edits, retain the original modes, and roll back if the second rename fails.
    targets = [directory / "PKGBUILD", directory / ".SRCINFO"]
    payloads = [recipe.read_bytes(), info.encode()]
    pending = []
    backups = []
    try:
        for target, data, saved in zip(targets, payloads, original):
            if target.is_symlink() or (target.read_bytes() if target.exists() else None) != saved:
                raise ValueError(f"recipe changed during update: {target}")
            mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644
            for data_to_write, files in ((data, pending), (saved, backups)):
                if data_to_write is None:
                    files.append(None)
                    continue
                with tempfile.NamedTemporaryFile(dir=directory, prefix=f".{target.name}.codec-",
                                                 delete=False) as stream:
                    files.append(Path(stream.name))
                    stream.write(data_to_write)
                    os.fchmod(stream.fileno(), mode)
        os.replace(pending[0], targets[0])
        try:
            os.replace(pending[1], targets[1])
        except OSError:
            os.replace(backups[0], targets[0])
            raise
    finally:
        for path in pending + backups:
            if path is not None:
                path.unlink(missing_ok=True)


def sync(directory):
    name = directory.name
    if name not in CHROME | COMPOSITE:
        raise ValueError(f"unsupported codec recipe: {name}")
    if not (directory / "PKGBUILD").is_file():
        raise ValueError("missing PKGBUILD")
    files = [directory / "PKGBUILD", directory / ".SRCINFO"]
    if any(path.is_symlink() for path in files):
        raise ValueError("refusing symlinked recipe metadata")
    original = [path.read_bytes() if path.exists() else None for path in files]
    names = {name}
    if name == "vivaldi-ffmpeg":
        names.add(name + ":vivaldi")
    with tempfile.TemporaryDirectory(prefix="codec-sync-") as work:
        work = Path(work)
        stage = work / name
        run(["bash", "-c", 'set -euo pipefail; source "$1"; pkg::stage_update_recipe "$2" "$3"',
             "_", str(ROOT / ".mise/lib/pkg/update.sh"), str(directory), str(stage)])
        recipe = stage / "PKGBUILD"
        versions = latest(stage, names)
        target = versions[name]
        if name in CHROME:
            target = validate(target, BROWSER_VERSION, name)
            old = validate(field(recipe, "pkgver"), BROWSER_VERSION, name)
            order = compare(target, old, name)
            run(["bash", str(directory / "update-chrome-ref.sh"), target, str(recipe)])
        else:
            if not isinstance(target, str) or target.count("_") != 1:
                raise ValueError(f"invalid combined version: {target!r}")
            ffmpeg, chromium = target.split("_")
            ffmpeg = validate(ffmpeg, FFMPEG_VERSION, "FFmpeg")
            chromium = validate(chromium, BROWSER_VERSION, "Chromium")
            old_ffmpeg = validate(field(recipe, "_ffmpeg_pkgver"), FFMPEG_VERSION, "local FFmpeg")
            old_chromium = validate(field(recipe, "_chromium_version"), BROWSER_VERSION, "local Chromium")
            ffmpeg_order = compare(ffmpeg, old_ffmpeg, "FFmpeg")
            chromium_order = compare(chromium, old_chromium, "Chromium")
            if ffmpeg.split(".")[0] != old_ffmpeg.split(".")[0]:
                raise ValueError("FFmpeg major changed; review codec ABI and patches manually")
            order = max(ffmpeg_order, chromium_order)
            old = old_ffmpeg + "_" + old_chromium
            args = ["bash", str(directory / "update-ffmpeg-ref.sh"), chromium, str(recipe)]
            if name == "vivaldi-ffmpeg":
                browser = validate(versions[name + ":vivaldi"], BROWSER_VERSION, "Vivaldi")
                major = ".".join(browser.split(".")[:2])
                compare(major, validate(field(recipe, "_vivaldi_major_version"),
                                        r"[0-9]+\.[0-9]+", "local Vivaldi"), "Vivaldi")
                args.append(major)
            run(args)
            set_field(recipe, "_ffmpeg_pkgver", ffmpeg)
        ref = validate(field(recipe, "_chromium_ffmpeg_ref"), r"[0-9a-f]{40}", "FFmpeg source revision")

        # The fixed-name sigs.base64 source must not be reused from an older
        # shared source cache. Never alter the original recipe on a failed sum.
        sources = work / "sources"
        sources.mkdir()
        env = dict(os.environ, SRCDEST=str(sources))
        if order > 0:
            set_field(recipe, "pkgrel", "1")
        run(["updpkgsums"], cwd=stage, env=env)
        if order == 0 and recipe.read_bytes() != original[0]:
            release = validate(field(recipe, "pkgrel"), r"[0-9]+(?:\.[0-9]+)?", "pkgrel")
            parts = release.split(".")
            parts[-1] = str(int(parts[-1]) + 1)
            set_field(recipe, "pkgrel", ".".join(parts))
        info = run(["makepkg", "--printsrcinfo"], cwd=stage, env=env, capture=True).stdout
        if (metadata(info, "pkgbase") != name or metadata(info, "pkgname") != name
                or metadata(info, "pkgver") != target
                or metadata(info, "pkgrel") != field(recipe, "pkgrel")
                or ref not in info):
            raise ValueError("generated .SRCINFO does not match the codec version and source revision")
        if recipe.read_bytes() == original[0] and info.encode() == original[1]:
            print(f"{name}: already synchronized ({target})")
            return
        install_pair(directory, recipe, info, original)
        print(f"{name}: synchronized {old} -> {target}; PKGBUILD and .SRCINFO updated")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: codec-sync.py <package-directory>")
        sync(Path(sys.argv[1]).resolve())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"error: codec update: {exc}", file=sys.stderr)
        sys.exit(1)
