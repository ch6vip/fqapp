"""Exercise the history guard against actual Git commit graphs."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check_pr_history.py"


class PrHistoryGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.repo = Path(cls.temp.name) / "repo"
        subprocess.run(["git", "init", "-q", str(cls.repo)], check=True)
        commands = []
        for index in range(1002):
            message = f"Commit {index}\n".encode()
            commands.append(
                b"commit refs/heads/main\n"
                + f"committer Test <test@example.invalid> {1700000000 + index} +0000\n".encode()
                + f"data {len(message)}\n".encode() + message + b"\n"
            )
        subprocess.run(
            ["git", "-C", str(cls.repo), "fast-import", "--quiet"],
            input=b"".join(commands), check=True,
        )
        cls.commits = subprocess.run(
            ["git", "-C", str(cls.repo), "rev-list", "--reverse", "main"],
            capture_output=True, text=True, check=True,
        ).stdout.splitlines()

    def check_range(self, start, end, cwd=None):
        return subprocess.run(
            ["python3", str(SCRIPT), self.commits[start], self.commits[end]],
            cwd=cwd or self.repo, capture_output=True, text=True,
        )

    def test_exactly_500_new_commits_pass(self):
        result = self.check_range(0, 500)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"new_commits": 500', result.stdout)

    def test_501_new_commits_fail(self):
        result = self.check_range(0, 501)
        self.assertEqual(result.returncode, 1)
        self.assertIn('"new_commits": 501', result.stdout)
        self.assertIn("cherry-pick", result.stderr)

    def test_large_existing_history_does_not_block_small_pr(self):
        result = self.check_range(1000, 1001)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"new_commits": 1', result.stdout)

    def test_diverged_base_counts_only_incoming_commits(self):
        # Base has its own commit after the fork; only the head-side commit is new.
        base = subprocess.run(
            ["git", "commit-tree", self.commits[1000] + "^{tree}", "-p", self.commits[1000]],
            cwd=self.repo, input="Independent base update\n", capture_output=True,
            text=True, check=True,
            env={**os.environ,
                 "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                 "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"},
        ).stdout.strip()
        result = subprocess.run(
            ["python3", str(SCRIPT), base, self.commits[1001]],
            cwd=self.repo, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"new_commits": 1', result.stdout)

    def test_shallow_history_fails_closed(self):
        shallow = Path(self.temp.name) / "shallow"
        subprocess.run(
            ["git", "clone", "--quiet", "--depth=1", "--branch=main",
             self.repo.as_uri(), str(shallow)], check=True,
        )
        result = self.check_range(1001, 1001, cwd=shallow)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Full commit history is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
