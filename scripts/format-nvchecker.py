#!/usr/bin/env python3
"""Validate and minimally format per-package nvchecker configurations."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any


BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")
HEADER = re.compile(r"^\[([^\]]+)\]\s*$")


def package_pkgbase(pkg_dir: Path) -> str:
    srcinfo = pkg_dir / ".SRCINFO"
    if srcinfo.is_file():
        for line in srcinfo.read_text(encoding="utf-8").splitlines():
            if line.startswith("pkgbase = "):
                return line.removeprefix("pkgbase = ").strip()

    text = (pkg_dir / "PKGBUILD").read_text(encoding="utf-8")

    for key in ("pkgbase", "pkgname"):
        match = re.search(
            rf"(?m)^{key}=([A-Za-z0-9@._+:-]+)\s*(?:#.*)?$",
            text,
        )
        if match:
            return match.group(1)

        match = re.search(
            rf"""(?m)^{key}=(['"])([^'"$]+)\1\s*(?:#.*)?$""",
            text,
        )
        if match:
            return match.group(2)

    return pkg_dir.name


def decode_header(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"'):
        return json.loads(raw)
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1]
    return raw


def encode_header(name: str) -> str:
    return name if BARE_KEY.fullmatch(name) else json.dumps(name)


def table_names(data: dict[str, Any]) -> list[str]:
    return [name for name, value in data.items() if isinstance(value, dict)]


def validate_data(
    data: dict[str, Any],
    expected: str,
) -> list[str]:
    errors: list[str] = []
    sections = table_names(data)

    if "__config__" in sections:
        errors.append("[__config__] is not supported by pkgctl per-package configs")

    if expected not in sections:
        errors.append(f"missing [{expected}] section")

    allowed_prefix = f"{expected}:"
    extras = [
        section
        for section in sections
        if section != expected
        and section != "__config__"
        and not section.startswith(allowed_prefix)
    ]
    if extras:
        errors.append("unsupported top-level section(s): " + ", ".join(extras))

    for section in sections:
        value = data[section]
        if not isinstance(value, dict):
            continue

        if value.get("source") == "cmd":
            errors.append(f"[{section}] uses disallowed cmd source")

        for key in ("keyfile", "httptoken", "token"):
            if key in value:
                errors.append(f"[{section}] contains restricted property: {key}")

    return errors


def find_primary_section(data: dict[str, Any]) -> str | None:
    candidates = [
        section
        for section in table_names(data)
        if section != "__config__" and ":" not in section
    ]
    if len(candidates) == 1:
        return candidates[0]
    return None


def rename_section_family(text: str, old: str, new: str) -> str:
    output: list[str] = []

    for line in text.splitlines():
        match = HEADER.match(line)
        if not match:
            output.append(line.rstrip())
            continue

        name = decode_header(match.group(1))
        if name == old:
            name = new
        elif name.startswith(f"{old}:"):
            name = f"{new}{name[len(old):]}"

        output.append(f"[{encode_header(name)}]")

    return "\n".join(output).rstrip() + "\n"


def inspect_config(
    pkg_dir: Path,
    *,
    check: bool,
    quiet: bool,
) -> tuple[bool, bool]:
    config = pkg_dir / ".nvchecker.toml"
    expected = package_pkgbase(pkg_dir)
    text = config.read_text(encoding="utf-8")

    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        if not quiet:
            print(f"error       {pkg_dir.name}: invalid TOML: {exc}")
        return False, False

    changed = False
    primary = find_primary_section(data)

    if expected not in table_names(data) and primary and primary != expected:
        text = rename_section_family(text, primary, expected)
        changed = True

        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError as exc:
            if not quiet:
                print(f"error       {pkg_dir.name}: formatter produced invalid TOML: {exc}")
            return False, False

    normalized = "\n".join(line.rstrip() for line in text.splitlines()).rstrip() + "\n"
    if normalized != text:
        text = normalized
        changed = True

    errors = validate_data(data, expected)
    if errors:
        if not quiet:
            for error in errors:
                print(f"error       {pkg_dir.name}: {error}")
        return False, changed

    if changed:
        if check:
            if not quiet:
                print(f"needs-format {pkg_dir.name}: {config}")
        else:
            config.write_text(text, encoding="utf-8")
            if not quiet:
                print(f"format      {pkg_dir.name}: {config}")
    elif not quiet:
        print(f"ok          {pkg_dir.name}: {config}")

    return True, changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and minimally format package nvchecker configs."
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help="Only process these package directories (default: all configs)",
    )
    parser.add_argument(
        "--packages-dir",
        type=Path,
        default=Path("packages"),
        help="package directory root (default: packages)",
    )
    parser.add_argument(
        "-c",
        "--check",
        action="store_true",
        help="check formatting without writing changes",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="only print the final summary",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not args.packages_dir.is_dir():
        print(f"error: packages directory not found: {args.packages_dir}", file=sys.stderr)
        return 2

    if args.packages:
        dirs = [args.packages_dir / name for name in args.packages]
    else:
        dirs = sorted(
            config.parent
            for config in args.packages_dir.glob("*/.nvchecker.toml")
        )

    errors = 0
    changed = 0
    checked = 0

    for pkg_dir in dirs:
        config = pkg_dir / ".nvchecker.toml"
        if not (pkg_dir / "PKGBUILD").is_file():
            if not args.quiet:
                print(f"error       {pkg_dir.name}: PKGBUILD not found")
            errors += 1
            continue

        if pkg_dir.name.endswith("-git"):
            if config.exists():
                if not args.quiet:
                    print(f"error       {pkg_dir.name}: VCS package has .nvchecker.toml")
                errors += 1
            continue

        if not config.is_file():
            if args.packages:
                if not args.quiet:
                    print(f"error       {pkg_dir.name}: .nvchecker.toml not found")
                errors += 1
            continue

        ok, needs_change = inspect_config(
            pkg_dir,
            check=args.check,
            quiet=args.quiet,
        )
        checked += 1
        if not ok:
            errors += 1
        if needs_change:
            changed += 1

    print(f"summary: checked={checked} changed={changed} errors={errors}")

    if errors:
        return 1
    if args.check and changed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
