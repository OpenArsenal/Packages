"""Commit-aware pkgctl version checks for VCS packages."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib


def commit_names(directory):
    with (Path(directory) / ".nvchecker.toml").open("rb") as stream:
        config = tomllib.load(stream)
    return {
        name for name, settings in config.items()
        if isinstance(settings, dict)
        and settings.get("source") == "git"
        and settings.get("use_commit") is True
    }


def normalize(result, commits):
    """Compare a Git describe suffix to the remote commit, not via vercmp."""
    if result["pkgbase"] not in commits or result["status"] == "failure":
        return
    local = result["local_version"] or ""
    remote = result["upstream_version"] or ""
    # git describe versions end in .g<abbreviated commit>; require at least
    # seven hex digits. A full hash is not a valid generated package version.
    match = re.search(r"\.g([0-9a-f]{7,64})$", local, re.IGNORECASE)
    if not match or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", remote, re.IGNORECASE):
        result.update(status="failure", out_of_date=False,
                      message="cannot compare Git commits; rebuild manually to refresh pkgver")
        return
    current = remote.lower().startswith(match[1].lower())
    result.update(status="success", out_of_date=not current,
                  message=None if current else "upstream Git commit changed; rebuild required")


def check(mode, verbose, directories):
    commits = set().union(*(commit_names(path) for path in directories))
    proc = subprocess.run(
        ["pkgctl", "version", "check", "--verbose", "--json", *directories],
        stdout=subprocess.PIPE, text=True, check=False,
    )
    if proc.returncode not in (0, 2):
        print(f"error: pkgctl check exited {proc.returncode}", file=sys.stderr)
        return proc.returncode
    results = json.loads(proc.stdout)
    fields = {"pkgbase", "status", "message", "out_of_date",
              "local_version", "upstream_version"}
    if not isinstance(results, list) or len(results) != len(directories):
        raise ValueError("incomplete pkgctl JSON results")
    names = set()
    for result in results:
        if (not isinstance(result, dict) or not fields <= result.keys()
                or not isinstance(result["pkgbase"], str)
                or result["status"] not in ("success", "warning", "failure")
                or not isinstance(result["out_of_date"], bool)
                or any(result[key] is not None and not isinstance(result[key], str)
                       for key in ("message", "local_version", "upstream_version"))):
            raise ValueError("invalid pkgctl JSON result")
        if result["pkgbase"] in names:
            raise ValueError("duplicate pkgctl package result")
        names.add(result["pkgbase"])
        normalize(result, commits)
    if not commits <= names:
        raise ValueError("missing Git package results")

    failures = [item for item in results if item["status"] == "failure"]
    outdated = [item for item in results
                if item["status"] != "failure" and item["out_of_date"]]
    current = [item for item in results
               if item["status"] != "failure" and not item["out_of_date"]]

    if mode == "json":
        json.dump(results if verbose else failures + outdated, sys.stdout, indent=2)
        print()
    elif mode == "list":
        if not failures:
            for item in outdated:
                print(item["pkgbase"])
    else:
        if verbose and current:
            print("Up-to-date")
            for item in current:
                detail = item["message"] or "current version is latest"
                print(f"  ✓ {item['pkgbase']}: {item['local_version']} ({detail})")
        if outdated:
            print("Out-of-date")
            for item in outdated:
                name = item["pkgbase"]
                if name in commits:
                    print(f"  ! {name}: upstream Git commit changed "
                          f"({item['local_version']} -> {item['upstream_version']})")
                    if mode == "apply":
                        print(f"    Rebuild with: mise run pkg:build {name} --force")
                else:
                    print(f"  ! {name}: upgrade from version "
                          f"{item['local_version']} to {item['upstream_version']}")
        elif not failures and not (verbose and current):
            print("All checked packages are up to date.")
    for item in failures:
        print(f"error: {item['pkgbase']}: {item['message']}", file=sys.stderr)
    return 1 if failures else 0


def main():
    mode, *args = sys.argv[1:]
    try:
        if mode == "classify":
            # Emit one classification per path, in selection order.
            for path in args:
                print("commit" if commit_names(path) else "release")
            return 0
        verbose, *paths = args
        return check(mode, verbose == "true" or len(paths) == 1, paths)
    except (OSError, ValueError, TypeError) as exc:
        print(f"error: version check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
