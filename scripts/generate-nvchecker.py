#!/usr/bin/env python3
"""Generate per-package .nvchecker.toml files from feeds.json.

Only mappings that preserve the existing feed semantics are emitted. Existing
configs are left untouched unless --force is used.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_key(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_-]+", value):
        return value
    return toml_string(value)


def replacement_to_python(value: str) -> str:
    return re.sub(r"\$(\d+)", r"\\\1", value)


def render_config(feed: dict[str, Any], section_name: str) -> tuple[str | None, str | None]:
    name = str(feed.get("name") or "")
    feed_type = str(feed.get("type") or "")

    if not name:
        return None, "missing package name"

    if feed_type == "manual":
        return None, "manual"

    if feed_type == "vcs" or name.endswith("-git"):
        return None, "VCS package"

    if feed_type == "chromium-ffmpeg":
        ffmpeg = f"{section_name}:ffmpeg"
        chromium = f"{section_name}:chromium"
        return (
            "\n".join(
                [
                    f"[{toml_key(ffmpeg)}]",
                    'source = "github"',
                    'github = "FFmpeg/FFmpeg"',
                    "use_max_tag = true",
                    "include_regex = '^n[0-9]+\\.[0-9]+(?:\\.[0-9]+)?
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
                'sort_version_key = "vercmp"',
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

    elif feed_type == "1password-cli2":
        url = str(feed.get("url") or "")
        if not url:
            return None, "1password-cli2 missing url"

        lines.extend(
            [
                'source = "jq"',
                f"url = {toml_string(url)}",
                'filter = ".version"',
            ]
        )

    elif feed_type == "chrome":
        channel = str(feed.get("channel") or "stable")
        url = (
            "https://versionhistory.googleapis.com/v1/chrome/platforms/linux/"
            f"channels/{channel}/versions/all/releases"
            "?filter=endtime%3Dnone%2Cfraction%3E%3D0.5"
            "&order_by=version%20desc"
        )
        lines.extend(
            [
                'source = "jq"',
                f"url = {toml_string(url)}",
                'filter = ".releases[0].version"',
            ]
        )

    elif feed_type == "edge":
        repomd_url = str(feed.get("url") or "")
        if not repomd_url.endswith("/repodata/repomd.xml"):
            return None, "edge feed must point to repodata/repomd.xml"

        package = str(feed.get("package") or name.removesuffix("-bin"))
        repo_url = repomd_url.removesuffix("/repodata/repomd.xml")

        lines.extend(
            [
                'source = "rpmrepo"',
                f"pkg = {toml_string(package)}",
                f"repo = {toml_string(repo_url)}",
                'arch = "x86_64"',
                'sort_version_key = "vercmp"',
            ]
        )

    elif feed_type == "lmstudio":
        platform = str(feed.get("platform") or "linux/x64")
        latest_url = f"https://lmstudio.ai/download/latest/{platform}"
        escaped_platform = re.escape(platform)

        lines.extend(
            [
                'source = "httpheader"',
                f"url = {toml_string(latest_url)}",
                'header = "Location"',
                'method = "HEAD"',
                f"regex = {toml_string(rf'/{escaped_platform}/([^/]+)/')}",
                f"from_pattern = {toml_string(r'^([0-9]+(?:\.[0-9]+){2,4})-([0-9]+)$')}",
                f"to_pattern = {toml_string(r'\1.\2')}",
            ]
        )

    elif feed_type == "flutter":
        lines.extend(
            [
                'source = "regex"',
                'url = "https://raw.githubusercontent.com/flutter/flutter/master/CHANGELOG.md"',
                f"regex = {toml_string(r'(?m)^### \[?([0-9]+\.[0-9]+\.[0-9]+)')}",
            ]
        )

    else:
        return None, f"unsupported feed type: {feed_type or '<empty>'}"

    return "\n".join(lines) + "\n", None


def load_feeds(path: Path) -> dict[str, dict[str, Any]]:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)

    packages = data.get("packages")
    if not isinstance(packages, list):
        raise ValueError("feeds.json does not contain a packages array")

    result: dict[str, dict[str, Any]] = {}
    for item in packages:
        if not isinstance(item, dict):
            continue

        name = str(item.get("name") or "")
        if not name:
            continue
        if name in result:
            raise ValueError(f"duplicate feeds.json entry: {name}")

        result[name] = item

    return result


def package_dirs(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}

    if not root.is_dir():
        raise ValueError(f"packages directory not found: {root}")

    for child in sorted(root.iterdir()):
        if child.is_dir() and (child / "PKGBUILD").is_file():
            result[child.name] = child

    return result


def package_pkgbase(pkg_dir: Path) -> str:
    srcinfo = pkg_dir / ".SRCINFO"
    if srcinfo.is_file():
        for line in srcinfo.read_text(encoding="utf-8").splitlines():
            if line.startswith("pkgbase = "):
                return line.removeprefix("pkgbase = ").strip()

    pkgbuild = pkg_dir / "PKGBUILD"
    text = pkgbuild.read_text(encoding="utf-8")

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate package .nvchecker.toml files from feeds.json."
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help="Only process these package names (default: all current packages)",
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
        help="overwrite existing .nvchecker.toml files when a mapping exists",
    )
    parser.add_argument(
        "-n",
        "--dry-run",
        action="store_true",
        help="show what would be generated without writing files",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail when a non-VCS package is neither covered nor explicitly unsupported",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress per-package output",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    feeds = load_feeds(args.feeds)
    packages = package_dirs(args.packages_dir)
    selected = set(args.packages)

    unknown = sorted(selected - packages.keys())
    if unknown:
        for name in unknown:
            print(f"error: package directory not found: {name}", file=sys.stderr)
        return 2

    names = sorted(selected or packages.keys())

    generated = 0
    existing = 0
    vcs = 0
    unsupported = 0
    unclassified = 0
    no_feed = 0
    errors = 0

    def report(message: str) -> None:
        if not args.quiet:
            print(message)

    for name in names:
        pkg_dir = packages[name]
        output = pkg_dir / ".nvchecker.toml"
        feed = feeds.get(name)

        is_vcs = name.endswith("-git") or (
            feed is not None and str(feed.get("type") or "") == "vcs"
        )
        if is_vcs:
            if output.exists():
                report(f"error       {name}: VCS package has .nvchecker.toml")
                errors += 1
            else:
                report(f"vcs         {name}")
                vcs += 1
            continue

        if output.exists() and not args.force:
            report(f"exists      {name}: {output}")
            existing += 1
            continue

        if feed is None:
            report(f"no-feed     {name}: no feeds.json entry")
            no_feed += 1
            continue

        if feed.get("nvchecker") is False:
            reason = str(feed.get("nvcheckerReason") or "explicitly unsupported")
            report(f"unsupported {name}: {reason}")
            unsupported += 1
            continue

        section_name = package_pkgbase(pkg_dir)
        config, reason = render_config(feed, section_name)
        if config is None:
            report(f"unclassified {name}: {reason}")
            unclassified += 1
            continue

        action = "would-write" if args.dry_run else "write"
        report(f"{action:<12}{name}: {output}")

        if not args.dry_run:
            output.write_text(config, encoding="utf-8")

        generated += 1

    print(
        f"summary: generated={generated} existing={existing} vcs={vcs} "
        f"unsupported={unsupported} unclassified={unclassified} "
        f"no_feed={no_feed} errors={errors}"
    )

    if args.strict and (unclassified or no_feed or errors):
        return 1

    return 0



if __name__ == "__main__":
    raise SystemExit(main())
",
                    'sort_version_key = "vercmp"',
                    'prefix = "n"',
                    "",
                    f"[{toml_key(chromium)}]",
                    'source = "jq"',
                    'url = "https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/stable/versions/all/releases?filter=endtime%3Dnone%2Cfraction%3E%3D0.5&order_by=version%20desc"',
                    'filter = ".releases[0].version"',
                    "",
                    f"[{toml_key(section_name)}]",
                    'source = "combiner"',
                    f"from = [{toml_string(ffmpeg)}, {toml_string(chromium)}]",
                    'format = "$1_$2"',
                ]
            )
            + "\n",
            None,
        )

    lines = [f"[{toml_key(section_name)}]"]

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
                'sort_version_key = "vercmp"',
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

    elif feed_type == "1password-cli2":
        url = str(feed.get("url") or "")
        if not url:
            return None, "1password-cli2 missing url"

        lines.extend(
            [
                'source = "jq"',
                f"url = {toml_string(url)}",
                'filter = ".version"',
            ]
        )

    elif feed_type == "chrome":
        channel = str(feed.get("channel") or "stable")
        url = (
            "https://versionhistory.googleapis.com/v1/chrome/platforms/linux/"
            f"channels/{channel}/versions/all/releases"
            "?filter=endtime%3Dnone%2Cfraction%3E%3D0.5"
            "&order_by=version%20desc"
        )
        lines.extend(
            [
                'source = "jq"',
                f"url = {toml_string(url)}",
                'filter = ".releases[0].version"',
            ]
        )

    elif feed_type == "edge":
        repomd_url = str(feed.get("url") or "")
        if not repomd_url.endswith("/repodata/repomd.xml"):
            return None, "edge feed must point to repodata/repomd.xml"

        package = str(feed.get("package") or name.removesuffix("-bin"))
        repo_url = repomd_url.removesuffix("/repodata/repomd.xml")

        lines.extend(
            [
                'source = "rpmrepo"',
                f"pkg = {toml_string(package)}",
                f"repo = {toml_string(repo_url)}",
                'arch = "x86_64"',
                'sort_version_key = "vercmp"',
            ]
        )

    elif feed_type == "lmstudio":
        platform = str(feed.get("platform") or "linux/x64")
        latest_url = f"https://lmstudio.ai/download/latest/{platform}"
        escaped_platform = re.escape(platform)

        lines.extend(
            [
                'source = "httpheader"',
                f"url = {toml_string(latest_url)}",
                'header = "Location"',
                'method = "HEAD"',
                f"regex = {toml_string(rf'/{escaped_platform}/([^/]+)/')}",
                f"from_pattern = {toml_string(r'^([0-9]+(?:\.[0-9]+){2,4})-([0-9]+)$')}",
                f"to_pattern = {toml_string(r'\1.\2')}",
            ]
        )

    elif feed_type == "flutter":
        lines.extend(
            [
                'source = "regex"',
                'url = "https://raw.githubusercontent.com/flutter/flutter/master/CHANGELOG.md"',
                f"regex = {toml_string(r'(?m)^### \[?([0-9]+\.[0-9]+\.[0-9]+)')}",
            ]
        )

    else:
        return None, f"unsupported feed type: {feed_type or '<empty>'}"

    return "\n".join(lines) + "\n", None


def load_feeds(path: Path) -> dict[str, dict[str, Any]]:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)

    packages = data.get("packages")
    if not isinstance(packages, list):
        raise ValueError("feeds.json does not contain a packages array")

    result: dict[str, dict[str, Any]] = {}
    for item in packages:
        if not isinstance(item, dict):
            continue

        name = str(item.get("name") or "")
        if not name:
            continue
        if name in result:
            raise ValueError(f"duplicate feeds.json entry: {name}")

        result[name] = item

    return result


def package_dirs(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}

    if not root.is_dir():
        raise ValueError(f"packages directory not found: {root}")

    for child in sorted(root.iterdir()):
        if child.is_dir() and (child / "PKGBUILD").is_file():
            result[child.name] = child

    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate package .nvchecker.toml files from feeds.json."
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help="Only process these package names (default: all current packages)",
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
        help="overwrite existing .nvchecker.toml files when a mapping exists",
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
    packages = package_dirs(args.packages_dir)
    selected = set(args.packages)

    unknown = sorted(selected - packages.keys())
    if unknown:
        for name in unknown:
            print(f"error: package directory not found: {name}", file=sys.stderr)
        return 2

    names = sorted(selected or packages.keys())

    generated = 0
    existing = 0
    skipped = 0
    no_feed = 0

    for name in names:
        pkg_dir = packages[name]
        output = pkg_dir / ".nvchecker.toml"

        if output.exists() and not args.force:
            print(f"exists      {name}: {output}")
            existing += 1
            continue

        if name.endswith("-git"):
            print(f"skip        {name}: VCS package")
            skipped += 1
            continue

        feed = feeds.get(name)
        if feed is None:
            print(f"no-feed     {name}: no feeds.json entry")
            no_feed += 1
            continue

        config, reason = render_config(feed)
        if config is None:
            print(f"skip        {name}: {reason}")
            skipped += 1
            continue

        action = "would-write" if args.dry_run else "write"
        print(f"{action:<12}{name}: {output}")

        if not args.dry_run:
            output.write_text(config, encoding="utf-8")

        generated += 1

    print(
        f"summary: generated={generated} existing={existing} "
        f"skipped={skipped} no_feed={no_feed}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
