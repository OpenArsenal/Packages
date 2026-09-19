#!/usr/bin/env python3
"""Generate per-package .nvchecker.toml files from feeds.json.

The generator is intentionally conservative: it only emits configurations for
feed types that map directly to native nvchecker sources. Existing configs are
left untouched unless --force is used.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SUPPORTED_TYPES = {
    "github-release",
    "github-tags-filtered",
    "npm",
    "pypi",
    "snap",
}

SKIP_TYPES = {
    "manual",
    "vcs",
}


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_key(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_-]+", value):
        return value
    return toml_string(value)


def replacement_to_python(value: str) -> str:
    return re.sub(r"\$(\d+)", r"\\\1", value)


def render_config(feed: dict[str, Any]) -> tuple[str | None, str | None]:
    name = str(feed.get("name") or "")
    feed_type = str(feed.get("type") or "")

    if not name:
        return None, "missing package name"

    if name.endswith("-git"):
        return None, "VCS package"

    if feed_type in SKIP_TYPES:
        return None, feed_type

    if feed_type not in SUPPORTED_TYPES:
        return None, f"unsupported feed type: {feed_type or '<empty>'}"

    lines = [f"[{toml_key(name)}]"]

    if feed_type == "github-release":
        repo = str(feed.get("repo") or "")
        channel = str(feed.get("channel") or "stable")

        if not repo:
            return None, "github-release missing repo"
        if channel != "stable":
            return None, f"github-release channel not mapped: {channel}"

        lines.extend(
            [
                'source = "github"',
                f"github = {toml_string(repo)}",
                "use_latest_release = true",
                'from_pattern = "^[vV]"',
                'to_pattern = ""',
            ]
        )

    elif feed_type == "github-tags-filtered":
        repo = str(feed.get("repo") or "")
        tag_regex = str(feed.get("tagRegex") or "")
        version_regex = str(feed.get("versionRegex") or "")
        version_format = str(feed.get("versionFormat") or "")

        if not repo:
            return None, "github-tags-filtered missing repo"
        if not tag_regex:
            return None, "github-tags-filtered missing tagRegex"

        lines.extend(
            [
                'source = "github"',
                f"github = {toml_string(repo)}",
                "use_max_tag = true",
                f"include_regex = {toml_string(tag_regex)}",
            ]
        )

        if version_regex or version_format:
            if not version_regex or not version_format:
                return None, "versionRegex/versionFormat must be paired"
            lines.extend(
                [
                    f"from_pattern = {toml_string(version_regex)}",
                    f"to_pattern = {toml_string(replacement_to_python(version_format))}",
                ]
            )
        else:
            lines.extend(
                [
                    'from_pattern = "^[vV]"',
                    'to_pattern = ""',
                ]
            )

    elif feed_type == "npm":
        package = str(feed.get("package") or "")
        dist_tag = str(feed.get("distTag") or "latest")

        if not package:
            return None, "npm missing package"
        if dist_tag != "latest":
            return None, f"npm distTag not mapped: {dist_tag}"

        lines.extend(
            [
                'source = "npm"',
                f"npm = {toml_string(package)}",
            ]
        )

    elif feed_type == "pypi":
        project = str(feed.get("project") or "")
        allow_prerelease = bool(feed.get("allowPrerelease", False))

        if not project:
            return None, "pypi missing project"

        lines.extend(
            [
                'source = "pypi"',
                f"pypi = {toml_string(project)}",
            ]
        )
        if allow_prerelease:
            lines.append("use_pre_release = true")

    elif feed_type == "snap":
        package = str(feed.get("package") or "")
        channel = str(feed.get("channel") or "stable")

        if not package:
            return None, "snap missing package"

        lines.extend(
            [
                'source = "snapcraft"',
                f"snap = {toml_string(package)}",
                f"channel = {toml_string(channel)}",
            ]
        )

    return "\n".join(lines) + "\n", None


def load_feeds(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)

    packages = data.get("packages")
    if not isinstance(packages, list):
        raise ValueError("feeds.json does not contain a packages array")

    return [item for item in packages if isinstance(item, dict)]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate package .nvchecker.toml files from feeds.json."
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help="Only process these package names (default: all feeds)",
    )
    parser.add_argument(
        "--feeds",
        type=Path,
        default=Path("feeds.json"),
        help="feeds.json path (default: feeds.json)",
    )
    parser.add_argument(
        "--packages-dir",
        type=Path,
        default=Path("packages"),
        help="package directory root (default: packages)",
    )
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="overwrite existing .nvchecker.toml files",
    )
    parser.add_argument(
        "-n",
        "--dry-run",
        action="store_true",
        help="show what would be generated without writing files",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    feeds = load_feeds(args.feeds)
    selected = set(args.packages)
    known = {str(feed.get("name") or "") for feed in feeds}

    unknown = sorted(selected - known)
    if unknown:
        for name in unknown:
            print(f"error: package not found in feeds.json: {name}", file=sys.stderr)
        return 2

    generated = 0
    existing = 0
    skipped = 0
    missing = 0

    for feed in feeds:
        name = str(feed.get("name") or "")
        if not name or (selected and name not in selected):
            continue

        pkg_dir = args.packages_dir / name
        pkgbuild = pkg_dir / "PKGBUILD"
        output = pkg_dir / ".nvchecker.toml"

        if not pkgbuild.is_file():
            print(f"missing  {name}: {pkgbuild}")
            missing += 1
            continue

        config, reason = render_config(feed)
        if config is None:
            print(f"skip     {name}: {reason}")
            skipped += 1
            continue

        if output.exists() and not args.force:
            print(f"exists   {name}: {output}")
            existing += 1
            continue

        action = "would-write" if args.dry_run else "write"
        print(f"{action:<11}{name}: {output}")

        if not args.dry_run:
            output.write_text(config, encoding="utf-8")

        generated += 1

    print(
        f"summary: generated={generated} existing={existing} "
        f"skipped={skipped} missing={missing}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
