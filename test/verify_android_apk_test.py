"""APK signature classification, with external SDK commands isolated."""
import argparse
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("apk_verifier", ROOT / "scripts/verify_android_apk.py")
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)
MISSING_MANIFEST = "DOES NOT VERIFY\nERROR: Missing META-INF/MANIFEST.MF\n"


class SignatureClassificationTest(unittest.TestCase):
    def run_verifier(self, output=MISSING_MANIFEST, material=None, abi=None,
                     fixture_abi=None):
        with tempfile.TemporaryDirectory(prefix="fqapp-apk-signature-") as temporary:
            root = Path(temporary)
            apk = root / "fixture.apk"
            verify_abi = abi or "arm64-v8a"
            required = verifier.REQUIRED_LIBRARIES_BY_ABI[fixture_abi or verify_abi]
            with zipfile.ZipFile(apk, "w") as archive:
                for name in required:
                    archive.writestr(name, b"native fixture; ELF checker is isolated")
                if material == "v1":
                    archive.writestr("META-INF/CERT.SF", b"broken signature fixture")
            if material == "v2":
                raw = apk.read_bytes()
                with zipfile.ZipFile(apk) as archive:
                    central = archive.start_dir
                # Even an invalid block must not be treated as unsigned.
                block = struct.pack("<Q", 24) * 2 + b"APK Sig Block 42"
                raw = bytearray(raw[:central] + block + raw[central:])
                struct.pack_into("<I", raw, len(raw) - 22 + 16, central + len(block))
                apk.write_bytes(raw)
            tools = root / "tools"
            (tools / "lib").mkdir(parents=True)
            (tools / "lib/apksigner.jar").touch()
            report_dir = root / "report"
            report_dir.mkdir()
            args = argparse.Namespace(apk=str(apk), build_tools=str(tools),
                                      abi=verify_abi,
                                      allow_unsigned=True, expected_signer_sha256=None,
                                      expected_version_name=None)
            report = {"checks": {}}

            def command(_arguments, _directory, name, **_kwargs):
                if name == "apksigner.log":
                    return output
                if name == "aapt-badging.log":
                    return "package: name='com.fqapp.fqapp' versionCode='127' versionName='1.0.122'\n"
                return "fixture SDK command succeeded\n"

            with mock.patch.object(verifier, "executable", return_value="fixture-tool"), \
                    mock.patch.object(verifier, "run_logged", side_effect=command):
                verifier.verify(args, report_dir, report)
            return report

    def test_gradle_unsigned_missing_manifest_is_recognized(self):
        report = self.run_verifier()
        self.assertEqual(report["status"], "passed")
        self.assertFalse(report["signature"]["signed"])

    def test_armeabi_v7a_apk_verifies_with_its_own_abi(self):
        report = self.run_verifier(abi="armeabi-v7a")
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["abi"], "armeabi-v7a")

    def test_arm64_apk_rejected_under_armeabi_v7a(self):
        # An ARM64 APK verified as 32-bit must fail: its native libraries
        # live under lib/arm64-v8a, not lib/armeabi-v7a.
        with self.assertRaises(verifier.VerificationError):
            self.run_verifier(abi="armeabi-v7a", fixture_abi="arm64-v8a")

    def test_missing_manifest_does_not_hide_broken_v1_signature(self):
        with self.assertRaises(verifier.VerificationError):
            self.run_verifier(material="v1")

    def test_missing_manifest_does_not_hide_broken_signing_block(self):
        with self.assertRaises(verifier.VerificationError):
            self.run_verifier(material="v2")

    def test_unknown_diagnostics_do_not_mean_unsigned(self):
        for output in ["", "DOES NOT VERIFY\nERROR: digest mismatch\n",
                       MISSING_MANIFEST + "ERROR: malformed signing block\n"]:
            with self.subTest(output=output), self.assertRaises(verifier.VerificationError):
                self.run_verifier(output=output)


if __name__ == "__main__":
    unittest.main()
