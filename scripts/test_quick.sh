#!/usr/bin/env bash
# Tiered Flutter test runner for the development loop.
#
# The full suite (2000+ tests, minutes locally) is the pre-handoff gate, and
# CI runs the same set on every master push (.github/workflows/android-apk.yml
# `flutter test --no-pub --concurrency=2`, plus windows.yml). The daily loop
# rarely needs it: this script runs the tier below it — the test files of the
# modules actually being touched, in seconds.
#
# Usage:
#   ./scripts/test_quick.sh home                  # every test file with 'home' in its name
#   ./scripts/test_quick.sh home search rank      # several modules at once
#   ./scripts/test_quick.sh home_provider_test.dart   # bare names resolve under test/
#   ./scripts/test_quick.sh test/home_page_test.dart  # explicit paths pass through
#   ./scripts/test_quick.sh --all                 # the full suite, same gate CI runs
#   ./scripts/test_quick.sh --concurrency=8 home  # more parallel shards (default: Flutter's)
#
# A module token is matched as a substring of the test file name, so 'home'
# also picks up home_scroll_cost_test.dart and real_home_payload_test.dart.
# A token matching nothing is a hard error: a typo must not quietly run less
# than the caller asked for (same rule as build_rust_backend.sh).
#
# --no-pub is always passed: after the first `flutter pub get`, the resolve
# at the start of every run is pure startup overhead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

usage() {
  sed -n '/^# Usage:/,/^# A module token/p' "$0" | sed 's/^# \{0,1\}//'
}

concurrency=()
files=()
want_all=0

if [[ $# -eq 0 ]]; then
  echo "test_quick.sh: nothing to run — name modules, test files, or --all." >&2
  usage >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --all)
      want_all=1
      ;;
    --concurrency=*)
      [[ "${arg#--concurrency=}" =~ ^[0-9]+$ ]] || {
        echo "test_quick.sh: --concurrency needs a number, got '$arg'" >&2
        exit 1
      }
      concurrency=("--concurrency=${arg#--concurrency=}")
      ;;
    -*)
      echo "test_quick.sh: unknown option '$arg'" >&2
      usage >&2
      exit 1
      ;;
    *.dart)
      if [[ -f "$arg" ]]; then
        files+=("$arg")
      elif [[ -f "test/$arg" ]]; then
        files+=("test/$arg")
      else
        echo "test_quick.sh: no such test file: $arg" >&2
        exit 1
      fi
      ;;
    *)
      # Word-splitting is the point here: one token expands to its file list.
      matched=$(ls test/*"${arg}"*_test.dart 2>/dev/null || true)
      if [[ -z "$matched" ]]; then
        echo "test_quick.sh: no test file matches module '$arg' (looked for test/*${arg}*_test.dart)" >&2
        exit 1
      fi
      for f in $matched; do
        files+=("$f")
      done
      ;;
  esac
done

if [[ $want_all -eq 1 ]]; then
  if [[ ${#files[@]} -gt 0 ]]; then
    echo "test_quick.sh: --all and module/file arguments are mutually exclusive" >&2
    exit 1
  fi
  echo "== full suite (the pre-handoff gate; CI runs the same set) =="
  exec flutter test --no-pub ${concurrency[@]+"${concurrency[@]}"}
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "test_quick.sh: nothing to run" >&2
  exit 1
fi

# Several tokens can match the same file (e.g. 'home' and 'provider'); dedupe
# while keeping the order so the printed list stays predictable.
deduped=()
for f in "${files[@]}"; do
  [[ " ${deduped[*]-} " == *" $f "* ]] || deduped+=("$f")
done

echo "== ${#deduped[@]} test file(s) =="
printf '  %s\n' "${deduped[@]}"
exec flutter test --no-pub ${concurrency[@]+"${concurrency[@]}"} "${deduped[@]}"
