"""Contracts for the independently packaged Google Chrome release channels."""

import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"
CHANNELS = {
    "google-chrome": ("stable", "chrome", "google-chrome", "", "google-chrome"),
    "google-chrome-beta": ("beta", "chrome-beta", "google-chrome-beta", "_beta", "google-chrome-beta"),
    "google-chrome-dev": ("unstable", "chrome-unstable", "google-chrome-unstable", "_dev", "google-chrome-unstable"),
    "google-chrome-canary": ("canary", "chrome-canary", "google-chrome-canary", "_canary", "google-chrome-canary"),
}


def add_file(archive, name, data, mode=0o644):
    entry = tarfile.TarInfo(name)
    entry.mode = mode
    entry.size = len(data)
    archive.addfile(entry, io.BytesIO(data))


class ChromeBrowserContracts(unittest.TestCase):
    def test_trackers_select_the_matching_official_debian_package(self):
        versions = {
            "stable": "158.0.1.1",
            "beta": "159.0.2.2",
            "unstable": "160.0.3.3",
            "canary": "161.0.4.4",
        }
        index = "\n\n".join(
            f"Package: google-chrome-{channel}\nVersion: {version}-1\nArchitecture: amd64"
            for channel, version in versions.items()
        ) + "\n"
        for name, (channel, *_) in CHANNELS.items():
            with self.subTest(package=name):
                config = tomllib.loads((PACKAGES / name / ".nvchecker.toml").read_text())[name]
                self.assertEqual(config["source"], "regex")
                self.assertEqual(
                    config["url"],
                    "https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages",
                )
                self.assertEqual(re.findall(config["regex"], index), [versions[channel]])
                # The archive URL explicitly pins Debian release 1.
                self.assertEqual(re.findall(config["regex"], index.replace("-1\n", "-2\n")), [])

    def test_packaging_preserves_vendor_payload_and_separates_file_ownership(self):
        with tempfile.TemporaryDirectory(prefix="chrome-browser-contract-") as work:
            work = Path(work)
            bindir = work / "bin"
            bindir.mkdir()
            mock = bindir / "bsdtar"
            mock.write_text('#!/bin/sh\nexec tar "$@"\n')
            mock.chmod(0o755)
            files_by_channel = {}
            for name, (channel, app, executable, icon_suffix, desktop) in CHANNELS.items():
                with self.subTest(package=name):
                    directory = PACKAGES / name
                    src = work / name / "src"
                    dst = work / name / "pkg"
                    src.mkdir(parents=True)
                    dst.mkdir()
                    for filename in ["eula_text.html", f"google-chrome-{channel}.sh"]:
                        (src / filename).write_bytes((directory / filename).read_bytes())

                    with tarfile.open(src / "data.tar.xz", "w:xz") as archive:
                        base = f"opt/google/{app}"
                        add_file(archive, f"{base}/chrome", b"browser", 0o755)
                        add_file(archive, f"{base}/{executable}", b"vendor launcher", 0o755)
                        add_file(archive, f"{base}/libffmpeg.so", b"vendor codec")
                        add_file(archive, f"{base}/product_logo_48{icon_suffix}.png", b"icon")
                        add_file(archive, f"{base}/WidevineCdm/LICENSE", b"license")
                        add_file(archive, f"{base}/cron/update", b"Debian update")
                        add_file(archive, "etc/cron.daily/google-chrome", b"Debian update")
                        add_file(archive, "etc/apt/sources.list.d/google-chrome.list", b"APT")
                        add_file(
                            archive, f"usr/share/applications/{desktop}.desktop",
                            b"[Desktop Entry]\nExec=google-chrome %U\nMimeType=x-scheme-handler/ftp;\n",
                        )

                    env = dict(os.environ, srcdir=str(src), pkgdir=str(dst), CARCH="x86_64",
                               PATH=str(bindir) + os.pathsep + os.environ["PATH"])
                    subprocess.run(
                        ["bash", "-ec", 'source "$1"; package', "_", str(directory / "PKGBUILD")],
                        cwd=src, env=env, check=True,
                    )
                    self.assertEqual((dst / base / "chrome").read_bytes(), b"browser")
                    self.assertEqual((dst / base / "libffmpeg.so").read_bytes(), b"vendor codec")
                    launcher = dst / "usr/bin" / f"google-chrome-{channel}"
                    self.assertEqual(launcher.read_bytes(),
                                     (directory / f"google-chrome-{channel}.sh").read_bytes())
                    self.assertTrue(os.access(launcher, os.X_OK))
                    self.assertFalse((dst / "etc/apt").exists())
                    self.assertFalse((dst / "etc/cron.daily").exists())
                    self.assertFalse((dst / base / "cron").exists())
                    self.assertTrue((dst / "usr/share/licenses" / name / "eula_text.html").is_file())
                    self.assertTrue(
                        (dst / "usr/share/icons/hicolor/48x48/apps" / f"{desktop}.png").is_file()
                    )
                    info = (directory / ".SRCINFO").read_text()
                    for filename in ["eula_text.html", f"google-chrome-{channel}.sh"]:
                        self.assertIn(hashlib.sha512((directory / filename).read_bytes()).hexdigest(), info)
                    for field in re.findall(r"^\s*source(?:_[a-z0-9_]+)? = (https?://\S+)", info, re.M):
                        self.assertTrue(field.startswith("https://dl.google.com/linux/chrome/deb/"))
                    if name in {"google-chrome", "google-chrome-canary"}:
                        self.assertIn(f"\tconflicts = {name}-ffmpeg\n", info)
                        self.assertIn(f"\treplaces = {name}-ffmpeg\n", info)
                    files = {str(p.relative_to(dst)) for p in dst.rglob("*")
                             if p.is_file() or p.is_symlink()}
                    for other, previous in files_by_channel.items():
                        self.assertFalse(files & previous, f"{name} overlaps {other}: {files & previous}")
                    files_by_channel[name] = files


if __name__ == "__main__":
    unittest.main()
