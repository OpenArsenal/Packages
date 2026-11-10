#!/usr/bin/env python3
"""Check local PKGBUILD source files against their recorded .SRCINFO hashes.

No network access or Arch tooling is required. Remote URLs and source
entries with SKIP checksums are not hashed.
"""

from __future__ import annotations

import hashlib
from collections import defaultdict
from pathlib import Path
import sys

HASHES = {
    "md5sums": hashlib.md5,
    "sha1sums": hashlib.sha1,
    "sha224sums": hashlib.sha224,
    "sha256sums": hashlib.sha256,
    "sha384sums": hashlib.sha384,
    "sha512sums": hashlib.sha512,
    "b2sums": hashlib.blake2b,
}


def read_metadata(path: Path) -> dict[str, list[str]]:
    values: dict[str, list[str]] = defaultdict(list)
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.strip().partition(" = ")
        if sep:
            values[key].append(value)
    return values


def is_remote(source: str) -> bool:
    # Paths with an explicit protocol belong to makepkg's downloader.
    # Git's SCP-style URLs are also remote, not local files.
    return "://" in source or source.startswith("git@")


def hash_file(path: Path, make_hasher) -> str:
    digest = make_hasher()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_package(directory: Path) -> tuple[int, list[str]]:
    errors: list[str] = []
    verified = 0
    metadata_path = directory / ".SRCINFO"
    if not metadata_path.is_file():
        return 0, [f"{directory}: missing .SRCINFO"]

    fields = read_metadata(metadata_path)
    for key, sources in fields.items():
        if key != "source" and not key.startswith("source_"):
            continue
        suffix = key[len("source") :]
        checksums = []
        for name, algorithm in HASHES.items():
            recorded = fields.get(name + suffix, [])
            if recorded:
                if len(recorded) != len(sources):
                    errors.append(
                        f"{metadata_path}: {name + suffix} has {len(recorded)} entries "
                        f"but {key} has {len(sources)}"
                    )
                    continue
                checksums.append((name, algorithm, recorded))

        for index, spec in enumerate(sources):
            source = spec.split("::", 1)[-1]
            if is_remote(source):
                continue
            file = directory / source
            if not file.is_file():
                errors.append(f"{directory}: missing local source: {source}")
                continue
            for name, algorithm, recorded in checksums:
                expected = recorded[index]
                if expected == "SKIP":
                    continue
                actual = hash_file(file, algorithm)
                verified += 1
                if actual.lower() != expected.lower():
                    errors.append(
                        f"{directory}: {name + suffix} mismatch for {source}: "
                        f"expected {expected}, got {actual}"
                    )
    return verified, errors


def main(args: list[str]) -> int:
    root = Path(__file__).resolve().parents[1]
    directories = (
        [Path(arg) for arg in args]
        if args
        else sorted(path.parent for path in (root / "packages").glob("*/PKGBUILD"))
    )
    total = 0
    failures: list[str] = []
    for directory in directories:
        count, errors = check_package(directory)
        total += count
        failures.extend(errors)

    for error in failures:
        print(f"error: {error}", file=sys.stderr)
    if failures:
        print(f"{len(failures)} local-source validation error(s)", file=sys.stderr)
        return 1
    print(f"Verified {total} local source checksums across {len(directories)} package directories.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
