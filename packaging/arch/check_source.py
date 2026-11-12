"""Reject local build inputs missing from the corresponding Git archive."""

import subprocess
import sys

root = sys.argv[1]
subprocess.run(["git", "-C", root, "diff", "--quiet", "HEAD", "--"], check=True)
inputs = [
    "assets", "lib", "native", "third_party", "linux", "packaging", "scripts",
    "rust", ".cargo", ":(exclude)rust/target",
    "rust/build.rs", "rust/Cargo.toml", "rust/Cargo.lock",
    ":(top,glob)*.yaml", ":(top,glob)*.lock", ":(top,glob)*.cmake", "CMakeLists.txt",
    ":(exclude)linux/flutter/ephemeral",
]
# Deliberately include ignored assets: Flutter does not consult .gitignore.
unknown = subprocess.check_output(
    ["git", "-C", root, "ls-files", "--others", "-z", "--", *inputs]
).split(b"\0")
if any(unknown):
    sys.exit("Untracked build inputs require review; build from a clean Git export")
