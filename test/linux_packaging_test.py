"""Focused release-input and compiler-argument regressions; no Flutter build."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


class ReleaseInputsTest(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[1]
        scratch = source / "build/packaging-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source with spaces"
        (self.root / "packaging/arch").mkdir(parents=True)
        for name in ("build_release.sh", "check_source.py", "toolchain.cmake"):
            shutil.copy(source / "packaging/arch" / name,
                        self.root / "packaging/arch" / name)
        (self.root / "assets").mkdir()
        (self.root / ".gitignore").write_text("/build/\n/rust/target/\n*.private\n")
        (self.root / "rust/src").mkdir(parents=True)
        lock = tomllib.loads((source / "rust/Cargo.lock").read_text())
        cc_version = next(p["version"] for p in lock["package"] if p["name"] == "cc")
        (self.root / "rust/Cargo.toml").write_text(
            '[package]\nname="flag_probe"\nversion="0.1.0"\nedition="2021"\n'
            f'[build-dependencies]\ncc="={cc_version}"\n')
        (self.root / "rust/src/main.rs").write_text("fn main() {}\n")
        (self.root / "rust/probe.c").write_text("int c_value;\n")
        (self.root / "rust/probe.cc").write_text("int cpp_value;\n")
        (self.root / "rust/build.rs").write_text(
            'fn main() { cc::Build::new().file("probe.c").compile("c_probe");'
            'cc::Build::new().cpp(true).file("probe.cc").compile("cpp_probe"); }\n')
        self.run_command("cargo", "generate-lockfile", "--offline",
                         "--manifest-path", "rust/Cargo.toml")
        self.run_command("git", "init", "-q")
        self.run_command("git", "add", ".")
        self.run_command("git", "-c", "user.name=Test", "-c",
                         "user.email=test@example.invalid", "commit", "-qm", "fixture")

    def run_command(self, *args, **kwargs):
        result = subprocess.run(args, cwd=self.root,
                                capture_output=True, text=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_untracked_and_ignored_assets_are_rejected(self):
        for name in ("untracked.json", "ignored.private"):
            asset = self.root / "assets" / name
            asset.write_text("synthetic")
            result = subprocess.run(
                ["python", "packaging/arch/check_source.py", str(self.root)],
                cwd=self.root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Untracked build inputs", result.stderr)
            self.assertEqual(asset.read_text(), "synthetic")
            asset.unlink()

    def test_spaced_paths_reach_real_compilers_as_single_arguments(self):
        tools = Path(self.temp.name) / "tool bin"
        tools.mkdir()
        flutter = tools / "flutter"
        flutter.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess
subprocess.run(["cargo", "check", "--offline", "--quiet", "--manifest-path", "rust/Cargo.toml"], check=True)
out = pathlib.Path("build/linux/x64/release/bundle")
out.mkdir(parents=True)
(out / "flags.json").write_text(json.dumps({k: os.environ[k] for k in ("CARGO_ENCODED_RUSTFLAGS", "CFLAGS", "CXXFLAGS")}))
''')
        flutter.chmod(0o755)
        env = os.environ.copy()
        env.setdefault("CARGO_HOME", str(Path.home() / ".cargo"))
        env.update(PATH=str(tools) + os.pathsep + env["PATH"],
                   HOME=str(Path(self.temp.name) / "home with spaces"),
                   FLUTTER_ROOT=str(tools), PUB_CACHE=str(tools),
                   CARGO_ENCODED_RUSTFLAGS="--cfg\x1fexisting_encoded_flag",
                   RUSTFLAGS="--invalid-ignored-flag")
        self.run_command("bash", "packaging/arch/build_release.sh", env=env)
        bundle = self.root / "build/linux/x64/release/bundle"
        flags = json.loads((bundle / "flags.json").read_text())
        self.assertEqual(flags["CARGO_ENCODED_RUSTFLAGS"].split("\x1f")[:2],
                         ["--cfg", "existing_encoded_flag"])
        self.assertIn(f"--remap-path-prefix={self.root}=/usr/src/fqapp",
                      flags["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"))
        self.assertEqual((bundle / "source-commit.txt").read_text().strip(),
                         self.run_command("git", "rev-parse", "HEAD").stdout.strip())
        # An archive has no .git; its revision is supplied by the export caller.
        shutil.rmtree(self.root / ".git")
        shutil.rmtree(bundle)
        env["FQAPP_SOURCE_REVISION"] = "a" * 40
        self.run_command("bash", "packaging/arch/build_release.sh", env=env)
        self.assertEqual((bundle / "source-commit.txt").read_text().strip(), "a" * 40)
        self.run_command("git", "init", "-q")
        self.run_command("git", "add", ".")
        self.run_command("git", "-c", "user.name=Test", "-c",
                         "user.email=test@example.invalid", "commit", "-qm", "fixture")
        (bundle / "generated.cmake").write_text("# generated build output\n")
        self.run_command("python", "packaging/arch/check_source.py", str(self.root))


if __name__ == "__main__":
    unittest.main()
