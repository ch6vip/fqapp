#!/usr/bin/env bash
# Ratchet for the "files <= 500 lines, functions <= 80 lines" rule in AGENTS.md.
#
# The codebase already broke that rule in ~40 files and ~80 functions. Rewriting
# them all is not a step in any current task, but continuing to grow them is how
# the rule stops meaning anything. This gate therefore freezes today's debt: a
# measured file or function may shrink or move freely, and may never grow past
# the number recorded in scripts/line_budget.json.
#
# Usage:
#   ./scripts/check_line_budget.sh                       # check the working tree
#   ./scripts/check_line_budget.sh --report              # print current sizes, write nothing
#   ./scripts/check_line_budget.sh --update <paths...>   # accept new sizes for these paths ONLY
#
# --update takes paths so a change cannot silently bless an unrelated file that
# grew in some other branch's working tree. Every update is printed, so the
# diff shows up in review as an explicit budget increase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

BUDGET="scripts/line_budget.json"
FILE_LIMIT=500
FUNCTION_LIMIT=80

mode=check
update_paths=()
case "${1:-}" in
  --report) mode=report ;;
  --update)
    mode=update
    shift
    update_paths=("$@")
    if [[ ${#update_paths[@]} -eq 0 ]]; then
      echo "check_line_budget.sh: --update needs at least one path." >&2
      exit 2
    fi
    ;;
  "") ;;
  *)
    echo "check_line_budget.sh: unknown argument '$1'" >&2
    exit 2
    ;;
esac

# Dart function bodies are measured by brace matching at the declaration's own
# indentation, which is stable for this codebase's formatting (`dart format`).
python - "$mode" "$BUDGET" "$FILE_LIMIT" "$FUNCTION_LIMIT" "${update_paths[@]+"${update_paths[@]}"}" <<'PY'
import json
import os
import re
import sys

mode, budget_path, file_limit, function_limit, *update_paths = sys.argv[1:]
file_limit = int(file_limit)
function_limit = int(function_limit)

SKIP_PREFIXES = ('build/', 'rust/target/', 'lib/src/rust/', '.dart_tool/')
SOURCE_SUFFIXES = ('.dart', '.rs', '.c', '.cpp', '.h', '.py', '.ps1', '.sh')
FUNCTION_PATTERNS = (
    re.compile(r'Widget\s+build\s*\('),
    re.compile(r'^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)'),
)
TOP_LEVEL_TYPE = re.compile(r'^(?:abstract\s+|final\s+|sealed\s+|base\s+)*class\s+(\w+)')
RUST_TYPE = re.compile(r'^(?:pub\s+)?(?:struct|enum|impl|trait)\s+(?:\w+\s+for\s+)?(\w+)')


def sources():
    for base in ('lib', 'rust/src', 'native', 'scripts', 'tool', 'test'):
        for root, _dirs, files in os.walk(base):
            if root.startswith('.') or any(root.startswith(p.rstrip('/')) for p in SKIP_PREFIXES):
                continue
            for name in sorted(files):
                if not name.endswith(SOURCE_SUFFIXES):
                    continue
                path = os.path.join(root, name).replace(os.sep, '/')
                if any(path.startswith(p) for p in SKIP_PREFIXES):
                    continue
                yield path


def line_count(path):
    with open(path, encoding='utf-8', errors='ignore') as handle:
        return sum(1 for _ in handle)


def _bracket_delta(text):
    """Net count of opening minus closing brackets on one line.

    Deliberately crude (strings/comments are not parsed): the block-body
    measurement is just as crude, and a Dart declaration line almost never
    carries bracket characters inside a literal.
    """
    return sum(text.count(ch) for ch in '([{') - sum(text.count(ch) for ch in ')]}')


def function_last_line(lines, index):
    """Index of the last line belonging to the declaration starting at `index`.

    Two shapes are measured differently:

    * `Widget build(...) { ... }` — a brace block; it ends at the `}` that
      matches the declaration's own indentation.
    * `Widget build(...) => SizedBox(...)` — an expression body has no brace
      block of its own, so matching `}` would swallow every member that
      follows (that is how a 30-line builder used to be counted as 166).
      Such a body ends at the first line where the brackets balance and the
      statement terminates with `;`.
    """
    head = lines[index]
    expression = '=>' in head
    if not expression and index + 1 < len(lines):
        # `) =>` may be wrapped onto the next line by the formatter.
        expression = '=>' in lines[index + 1]
    if expression:
        balance = 0
        for pos in range(index, len(lines)):
            balance += _bracket_delta(lines[pos])
            if balance <= 0 and lines[pos].rstrip().endswith(';'):
                return pos
        return len(lines) - 1
    indent = len(head) - len(head.lstrip())
    end = index + 1
    while end < len(lines):
        body = lines[end]
        if body.strip() == '}' and (len(body) - len(body.lstrip())) == indent:
            return end - 1
        end += 1
    return len(lines) - 1


def long_functions(path):
    """(identity, line, length, symbol) for each declaration over the limit.

    The identity is '<path>::<type>.<method>' rather than a line number: a line
    number shifts as soon as anyone edits above the function, which would make
    the ratchet fire on edits that did not touch the function at all. Type +
    method survives insertions and is what the budget file is read for anyway.
    """
    if not path.endswith('.dart'):
        return []
    with open(path, encoding='utf-8', errors='ignore') as handle:
        lines = handle.read().split('\n')
    found = []
    owner = '?'
    seen = {}
    for index, text in enumerate(lines):
        if not text.startswith((' ', '\t')):
            match = TOP_LEVEL_TYPE.match(text) or RUST_TYPE.match(text)
            if match:
                owner = match.group(1)
        if not any(p.search(text) for p in FUNCTION_PATTERNS):
            continue
        length = function_last_line(lines, index) - index + 1
        if length <= function_limit:
            continue
        name = 'build' if 'Widget' in text else (re.search(r'fn\s+(\w+)', text) or [None, 'fn'])[1]
        base = f'{path}::{owner}.{name}'
        # Several overloads can share a name in one file; disambiguate by order.
        seen[base] = seen.get(base, 0) + 1
        identity = base if seen[base] == 1 else f'{base}#{seen[base]}'
        found.append((identity, index + 1, length, text.strip()[:80]))
    return found


current_files = {}
current_functions = {}
for path in sources():
    count = line_count(path)
    if count > file_limit:
        current_files[path] = count
    for identity, line, length, symbol in long_functions(path):
        current_functions[identity] = {'lines': length, 'line': line, 'symbol': symbol}

budget = {'files': {}, 'functions': {}}
if os.path.exists(budget_path):
    with open(budget_path, encoding='utf-8') as handle:
        budget = json.load(handle)

if mode == 'report':
    print(f'files over {file_limit} lines: {len(current_files)}')
    for path, count in sorted(current_files.items(), key=lambda kv: -kv[1]):
        print(f'  {count:5d}  {path}')
    print(f'functions over {function_limit} lines: {len(current_functions)}')
    for key, meta in sorted(current_functions.items(), key=lambda kv: -kv[1]['lines']):
        print(f"  {meta['lines']:5d}  {key}  (line {meta['line']})")
    sys.exit(0)

if mode == 'update':
    # Only the paths named on the command line may have their ceiling rewritten,
    # so a stray edit elsewhere cannot be blessed by an unrelated --update.
    for path in update_paths:
        if path in current_files:
            budget.setdefault('files', {})[path] = current_files[path]
        else:
            budget.get('files', {}).pop(path, None)
        for key in [k for k in budget.get('functions', {}) if k.split('::')[0] == path]:
            del budget['functions'][key]
        for key, meta in current_functions.items():
            if key.split('::')[0] == path:
                budget.setdefault('functions', {})[key] = meta
        print(f'updated budget for {path}')
    with open(budget_path, 'w', encoding='utf-8') as handle:
        json.dump(budget, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write('\n')
    sys.exit(0)

problems = []
for path, count in sorted(current_files.items()):
    allowed = budget.get('files', {}).get(path)
    if allowed is None:
        problems.append(f'{path}: {count} lines, over the {file_limit} limit and not in the budget')
    elif count > allowed:
        problems.append(f'{path}: {count} lines, budget is {allowed}')
for key, meta in sorted(current_functions.items()):
    allowed = budget.get('functions', {}).get(key)
    if allowed is None:
        problems.append(
            f"{key} (line {meta['line']}): {meta['lines']} lines, over the {function_limit} "
            'limit and not in the budget'
        )
    elif meta['lines'] > allowed['lines']:
        problems.append(
            f"{key} (line {meta['line']}): {meta['lines']} lines, budget is {allowed['lines']}"
        )

for path, allowed in sorted(budget.get('files', {}).items()):
    if path not in current_files and os.path.exists(path):
        print(f'note: {path} is now within {file_limit} lines — run --update to drop its budget entry')
    elif not os.path.exists(path):
        print(f'note: {path} no longer exists — run --update to drop its budget entry')

if problems:
    print(f'check_line_budget.sh: {len(problems)} item(s) exceed their budget', file=sys.stderr)
    for problem in problems:
        print(f'  {problem}', file=sys.stderr)
    print('Split the code, or accept the growth explicitly with --update <path>.', file=sys.stderr)
    sys.exit(1)

print(f'check_line_budget.sh: ok ({len(budget.get("files", {}))} files, '
      f'{len(budget.get("functions", {}))} functions under a recorded ceiling)')
PY
