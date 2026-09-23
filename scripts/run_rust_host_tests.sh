#!/usr/bin/env bash
# Builds the host Rust core and runs the real Dart -> flutter_rust_bridge -> Rust
# integration tests against it.
#
# Everything the tests touch is local: a temporary runtime directory and a mock
# upstream on 127.0.0.1. No device, no real device pool, no upstream traffic.
#
# Usage:
#   ./scripts/run_rust_host_tests.sh
#   ./scripts/run_rust_host_tests.sh --skip-build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    *) ;;
  esac
done

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> building the host Rust core..."
  ( cd "$APP_DIR" && cargo build --manifest-path "$MANIFEST" )
fi

case "$(uname -s)" in
  Darwin) LIBRARY_NAME="libfqapi_core.dylib" ;;
  *)      LIBRARY_NAME="libfqapi_core.so" ;;
esac
LIBRARY="$APP_DIR/rust/target/debug/$LIBRARY_NAME"
if [ ! -f "$LIBRARY" ]; then
  echo "错误：未找到宿主 Rust 核心 $LIBRARY" >&2
  exit 1
fi

export FQAPP_RUST_HOST_LIB="$LIBRARY"
echo "==> host core: $LIBRARY"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$LIBRARY"
else
  shasum -a 256 "$LIBRARY"
fi

( cd "$APP_DIR" && flutter test --no-pub test/rust_host_integration_test.dart )
