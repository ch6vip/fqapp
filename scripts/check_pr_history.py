#!/usr/bin/env python3
"""Reject PRs that introduce more than 500 commits relative to their base."""

import argparse
import json
import subprocess
import sys

MAX_COMMITS = 500


def check_history(base, head):
    # Resolve commits before constructing the revision range. Count base..head,
    # not merge-base..head: commits already reachable from base are not new.
    def resolve(revision):
        return subprocess.run(
            ["git", "rev-parse", "--verify", "--end-of-options", revision + "^{commit}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    base, head = resolve(base), resolve(head)
    if subprocess.run(
        ["git", "rev-parse", "--is-shallow-repository"],
        check=True, capture_output=True, text=True,
    ).stdout.strip() != "false":
        raise ValueError("Full commit history is required; use fetch-depth: 0.")
    count = int(subprocess.run(
        ["git", "rev-list", "--count", base + ".." + head],
        check=True, capture_output=True, text=True,
    ).stdout)
    return {"base": base, "head": head, "new_commits": count,
            "max_commits": MAX_COMMITS, "passed": count <= MAX_COMMITS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args()
    try:
        result = check_history(args.base, args.head)
    except (subprocess.CalledProcessError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result))
    if not result["passed"]:
        print(
            f"This PR introduces {result['new_commits']} commits; the limit is "
            f"{MAX_COMMITS}. Please create a branch from the latest upstream "
            "master and cherry-pick the intended changes, then open a new PR. "
            "Merging master into the old branch does not remove its old history.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
