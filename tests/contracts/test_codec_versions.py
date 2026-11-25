"""Regression tests for compatible FFmpeg maintenance release tracking."""
import pathlib
import re
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class CodecTrackingTests(unittest.TestCase):
    def test_only_compatible_ffmpeg_archives_are_selected(self):
        releases = "\n".join(
            f'<a href="ffmpeg-{version}{suffix}">download</a>'
            for version, suffix in [
                ("8.0.3", ".tar.xz"), ("8.1.1", ".tar.xz"),
                ("8.1.3", ".tar.xz"), ("8.1.3", ".tar.xz.asc"),
                ("8.2.0", ".tar.xz"), ("9.1", ".tar.xz"),
            ]
        )
        for name in ("vivaldi-ffmpeg", "chromium-ffmpeg"):
            with self.subTest(package=name):
                directory = ROOT / "packages" / name
                config = tomllib.loads((directory / ".nvchecker.toml").read_text())
                tracker = config[name + ":ffmpeg"]
                self.assertEqual(tracker["source"], "regex")
                self.assertEqual(tracker["url"], "https://ffmpeg.org/releases/")
                self.assertEqual(re.findall(tracker["regex"], releases), ["8.1.1", "8.1.3"])
                recipe = (directory / "PKGBUILD").read_text()
                self.assertIn("_chromium_patch_version=8.1.1", recipe)
                self.assertIn("/raw/2-${_chromium_patch_version}-1/", recipe)
                self.assertNotIn("/raw/2-${_ffmpeg_pkgver}-1/", recipe)


if __name__ == "__main__":
    unittest.main()
