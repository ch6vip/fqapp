#!/usr/bin/env bash
# Informational source-size report. No limits, baseline, or size-based failures.
# Usage: bash scripts/check_line_budget.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if [[ $# -ne 0 ]]; then
  echo "Usage: bash scripts/check_line_budget.sh (report only; no budget to update)" >&2
  exit 2
fi

python - <<'PY'
import subprocess
from pathlib import Path

suffixes = {'.dart', '.rs', '.c', '.cpp', '.h', '.py', '.ps1', '.sh'}
tracked = subprocess.check_output([
    'git', 'ls-files', '-z', '--',
    'lib', 'rust/src', 'native', 'scripts', 'tool', 'test',
]).decode('utf-8').split('\0')
sizes = []
for name in tracked:
    path = Path(name)
    if (not name or path.suffix not in suffixes or not path.is_file()
            or name.startswith('lib/src/rust/')
            or name == 'rust/src/frb_generated.rs'):
        continue
    with path.open(encoding='utf-8', errors='replace') as source:
        sizes.append((sum(1 for _ in source), name))

print('Source size report: informational only; no pass/fail line limits.')
print('Review cohesion, complexity, and readability rather than line counts.')
print(f'Tracked source files: {len(sizes)}; largest 20 shown (not a size limit):')
for count, name in sorted(sizes, key=lambda item: (-item[0], item[1]))[:20]:
    print(f'  {count:6d}  {name}')
PY
