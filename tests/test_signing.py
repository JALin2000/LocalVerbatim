#!/usr/bin/env python3
"""Signing-plan regression tests; no identity, network, UI or audio access."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("sign_app", Path(__file__).resolve().parents[1] / "scripts/sign_app.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


def macho(path, kind=2, endian="<"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack(endian + "IIII", 0xfeedfacf, 0x100000c, 0, kind))
    return path


def app_fixture(directory):
    app = Path(directory) / "LocalVerbatim.app"
    macho(app / "Contents/MacOS/LocalVerbatim")
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": "LocalVerbatim"}, stream)
    return app


class SigningPlanTests(unittest.TestCase):
    def test_all_macho_endianness_and_non_code(self):
        with tempfile.TemporaryDirectory() as directory:
            for endian in ("<", ">"):
                for kind in (1, 2, 6, 8):
                    self.assertEqual(signing.macho_type(macho(Path(directory) / "binary", kind, endian)), kind)
            text = Path(directory) / "worker.py"
            text.write_text("print('not native')")
            self.assertIsNone(signing.macho_type(text))

    def test_universal_and_malformed_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "universal"
            for wide in (False, True):
                for endian in ("<", ">"):
                    size = 32 if wide else 20
                    offset = 8 + size
                    header = struct.pack(endian + "II", 0xcafebabf if wide else 0xcafebabe, 1)
                    record = struct.pack(endian + ("IIQQII" if wide else "IIIII"),
                                         *([0x100000c, 0, offset, 16, 0, 0] if wide else [0x100000c, 0, offset, 16, 0]))
                    path.write_bytes(header + record + struct.pack("<IIII", 0xfeedfacf, 0x100000c, 0, 6))
                    self.assertEqual(signing.macho_type(path), 6)
            path.write_bytes(b"\xcf\xfa\xed\xfe")
            with self.assertRaises(ValueError):
                signing.macho_type(path)

    def test_inside_out_including_code_in_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            app = app_fixture(directory)
            python = macho(app / "Contents/Resources/Support/runtime/bin/python3.13")
            (python.parent / "python").symlink_to("python3.13")
            native = macho(app / "Contents/Resources/Support/runtime/lib/nested/native.so", 8)
            macho(app / "Contents/Resources/build-object.o", 1)
            plan = signing.signing_plan(app)
            paths = [target["path"] for target in plan]
            self.assertEqual(paths[-1], app.resolve())
            self.assertIn(native.resolve(), paths)
            self.assertEqual(paths.count(python.resolve()), 1)
            self.assertNotIn(app / "Contents/MacOS/LocalVerbatim", paths)
            self.assertFalse(any(path.suffix == ".o" for path in paths))
            self.assertLess(paths.index(native.resolve()), paths.index(app.resolve()))

    def test_nested_bundle_sealed_after_children(self):
        with tempfile.TemporaryDirectory() as directory:
            app = app_fixture(directory)
            nested = app_fixture(app / "Contents/Helpers")
            helper = macho(nested / "Contents/Frameworks/helper.dylib", 6)
            paths = [target["path"] for target in signing.signing_plan(app)]
            self.assertLess(paths.index(helper.resolve()), paths.index(nested.resolve()))
            self.assertLess(paths.index(nested.resolve()), paths.index(app.resolve()))

    def test_symlinks_must_resolve_inside_app(self):
        for destination in ("/outside-release", "missing", "bad"):
            with self.subTest(destination=destination), tempfile.TemporaryDirectory() as directory:
                app = app_fixture(directory)
                (app / "bad").symlink_to(destination)
                with self.assertRaises(ValueError):
                    signing.signing_plan(app)
        with tempfile.TemporaryDirectory() as directory:
            app = app_fixture(directory)
            outside = Path(directory) / "outside"
            outside.mkdir()
            (app / "bad").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "escapes"):
                signing.signing_plan(app)

    def test_public_commands_have_separate_minimal_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            app = app_fixture(directory)
            macho(app / "Contents/Resources/runtime/bin/python")
            macho(app / "Contents/Resources/runtime/lib/native.so", 8)
            commands = [signing.sign_command(target, "A" * 40, True) for target in signing.signing_plan(app)]
            for command in commands:
                self.assertNotIn("--deep", command)
                self.assertIn("--timestamp", command)
                self.assertIn("runtime", command)
            self.assertIn(str(signing.APP_ENTITLEMENTS), commands[-1])
            runtime = [command for command in commands if command[-1].endswith("/python")][0]
            self.assertIn(str(signing.RUNTIME_ENTITLEMENTS), runtime)
            library = [command for command in commands if command[-1].endswith(".so")][0]
            self.assertNotIn("--entitlements", library)
            with signing.RUNTIME_ENTITLEMENTS.open("rb") as stream:
                self.assertEqual(plistlib.load(stream), {})

    def test_identity_rejects_ad_hoc_development_missing_and_ambiguous(self):
        for identity in ("-", "Apple Development: Example", "Developer ID Installer: Example"):
            with self.assertRaises(ValueError):
                signing.identity_from_keychain(identity)
        with patch.object(signing, "run") as command:
            command.return_value.stdout = '  1) ' + 'A' * 40 + ' "Developer ID Application: Example (ABCDEFGHIJ)"\n'
            self.assertEqual(signing.identity_from_keychain("A" * 40), ("A" * 40, "ABCDEFGHIJ"))
            with self.assertRaises(ValueError):
                signing.identity_from_keychain("B" * 40)
            command.return_value.stdout *= 2
            with self.assertRaises(ValueError):
                signing.identity_from_keychain("A" * 40)

    def test_public_signature_requires_timestamp_runtime_and_same_team(self):
        good = "Authority=Developer ID Application: Example (ABCDEFGHIJ)\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Nov 19, 2026\nCodeDirectory flags=0x10000(runtime)\n"
        with patch.object(signing, "signature_details", return_value=good):
            self.assertEqual(signing.check_developer_signature("fixture"), "ABCDEFGHIJ")
            with self.assertRaises(ValueError):
                signing.check_developer_signature("fixture", expected_team="DIFFERENT1")
        for bad in (good.replace("runtime", "none"), good.replace("Timestamp=", "Signed Time="), good.replace("Developer ID Application:", "Apple Development:")):
            with patch.object(signing, "signature_details", return_value=bad), self.assertRaises(ValueError):
                signing.check_developer_signature("fixture")


if __name__ == "__main__":
    unittest.main()
