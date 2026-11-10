#!/usr/bin/env python3
"""Unit tests for the generic contract harness (no package tools required)."""

from pathlib import Path
import tempfile
import unittest

from check import launcher_contract, validate_metadata, validate_registry


class MetadataContractsTest(unittest.TestCase):
    def test_valid_minimal_split_package_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            (directory / ".SRCINFO").write_text(
                "pkgbase = demo\n\tpkgver = 1.2.3\n\tpkgrel = 2\n"
                "\tpkgname = demo\n\tpkgname = demo-extra\n",
                encoding="utf-8",
            )
            self.assertEqual(validate_metadata(directory), [])

    def test_missing_and_invalid_fields_are_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            self.assertIn("missing .SRCINFO", str(validate_metadata(directory)))
            (directory / ".SRCINFO").write_text(
                "pkgbase = demo\npkgver = \npkgrel = abc\npkgname = demo\n",
                encoding="utf-8",
            )
            errors = " ".join(validate_metadata(directory))
            self.assertIn("pkgver", errors)
            self.assertIn("pkgrel", errors)


class LauncherContractsTest(unittest.TestCase):
    def test_data_driven_contract_checks_flags_and_cli(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            package = root / "packages" / "demo"
            package.mkdir(parents=True)
            wrapper = package / "demo-flags-wrapper.sh"
            wrapper.write_text(
                "#!/bin/bash\n"
                "mapfile -t flags < <(grep -v '^#' \"$XDG_CONFIG_HOME/demo.conf\")\n"
                "exec @DEMO_EXEC@ \"${flags[@]}\" \"$@\"\n",
                encoding="utf-8",
            )
            spec = {
                "adapter": "token", "script": wrapper.name,
                "token": "@DEMO_EXEC@", "configs": ["demo.conf"],
            }
            self.assertEqual(launcher_contract(root, spec, "demo"), [])
            wrapper.write_text("#!/bin/bash\nexec @DEMO_EXEC@ \"$@\"\n", encoding="utf-8")
            errors = " ".join(launcher_contract(root, spec, "demo"))
            self.assertIn("contract-config", errors)

    def test_new_wrapper_requires_explicit_manifest_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            directory = root / "packages" / "newapp"
            directory.mkdir(parents=True)
            (directory / "PKGBUILD").write_text("pkgname=newapp\n")
            (directory / "newapp-flags-wrapper.sh").write_text("#!/bin/bash\n")
            errors = " ".join(validate_registry(
                root, {"schema": 1, "launchers": [], "behaviors": []}
            ))
            self.assertIn("missing launcher contract", errors)


if __name__ == "__main__":
    unittest.main()
