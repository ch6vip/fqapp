#!/usr/bin/env bash
# Build from a clean checkout; prefer a neutral source/SDK/pub-cache directory.
set -euo pipefail
root=$(pwd -P)
revision=${FQAPP_SOURCE_REVISION:-}
if [[ $(git rev-parse --show-toplevel 2>/dev/null || true) == "$root" ]]; then
  revision=$(git rev-parse HEAD)
  python packaging/arch/check_source.py "$root"
fi
[[ $revision =~ ^[0-9a-f]{40}$ ]] || { echo "Missing source revision" >&2; exit 2; }
: "${FLUTTER_ROOT:?Set FLUTTER_ROOT}"
: "${PUB_CACHE:?Set an isolated PUB_CACHE}"
export CARGO_ENCODED_RUSTFLAGS="$(python - "$root" "$HOME" <<'PY'
import os, sys
flags = (os.environ['CARGO_ENCODED_RUSTFLAGS'].split('\x1f')
         if 'CARGO_ENCODED_RUSTFLAGS' in os.environ
         else os.environ.get('RUSTFLAGS', '').split())
flags += [f'--remap-path-prefix={sys.argv[1]}=/usr/src/fqapp',
          f'--remap-path-prefix={sys.argv[2]}=/usr/src/build-home']
print('\x1f'.join(flag for flag in flags if flag), end='')
PY
)"
maps=$(python - "$root" "$HOME" <<'PY'
import shlex, sys
print(shlex.join([f'-ffile-prefix-map={sys.argv[1]}=/usr/src/fqapp',
                  f'-ffile-prefix-map={sys.argv[2]}=/usr/src/build-home']))
PY
)
export CFLAGS="${CFLAGS:-} $maps"
export CXXFLAGS="${CXXFLAGS:-} $maps"
# cc-rs otherwise splits even quoted C/C++ paths on whitespace.
export CC_SHELL_ESCAPED_FLAGS=1
export CMAKE_TOOLCHAIN_FILE="$root/packaging/arch/toolchain.cmake"
export CARGO_NET_OFFLINE=true
flutter build linux --release --no-pub -t lib/main.dart
# Provenance marker only after a successful build, never copied from old caches.
if [[ -n $revision ]]; then printf '%s\n' "$revision" > build/linux/x64/release/bundle/source-commit.txt; fi
