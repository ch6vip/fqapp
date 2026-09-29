#!/usr/bin/env bash
# Builds the Rust native core (rust/ -> libfqapi_core.so) for Android arm64 and
# copies it into android/app/src/main/jniLibs/arm64-v8a.
#
# This is the single entry point for the Rust build: it regenerates the
# flutter_rust_bridge bindings, cross-compiles with the pinned NDK, and places
# the shared library where Gradle packages it.
#
# Usage:
#   ./scripts/build_rust_backend.sh
#   ./scripts/build_rust_backend.sh --skip-codegen
#   ./scripts/build_rust_backend.sh --host-lib
#   ./scripts/build_rust_backend.sh --profile debug
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"

SKIP_CODEGEN=0
HOST_LIB=0
PROFILE=release
for arg in "$@"; do
  case "$arg" in
    --skip-codegen) SKIP_CODEGEN=1 ;;
    --host-lib)     HOST_LIB=1 ;;
    --profile)      PROFILE=release ;;
    debug)          PROFILE=debug ;;
    *) ;;
  esac
done

if ! command -v cargo >/dev/null 2>&1; then
  echo "错误：未找到 cargo，请先安装 Rust 工具链。" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "错误：找不到 Rust 核心清单 $MANIFEST" >&2
  exit 1
fi

FRB_VERSION=2.13.0
if [ "$SKIP_CODEGEN" -eq 0 ]; then
  if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    echo "错误：未找到 flutter_rust_bridge_codegen。" >&2
    echo "安装：cargo install flutter_rust_bridge_codegen --version $FRB_VERSION --locked" >&2
    exit 1
  fi
  echo "==> 生成 flutter_rust_bridge 绑定..."
  ( cd "$APP_DIR" && flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml )
fi

# Locate the NDK: explicit env first, then the SDK, then the standard
# local.properties file. Prefer the revision the project pins.
NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$NDK_ROOT" ]; then
  SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$SDK_ROOT" ] && [ -f "$APP_DIR/android/local.properties" ]; then
    SDK_ROOT="$(sed -n 's/^sdk\.dir=//p' "$APP_DIR/android/local.properties" | head -n 1)"
  fi
  if [ -n "$SDK_ROOT" ]; then
    if [ -d "$SDK_ROOT/ndk/28.2.13676358" ]; then
      NDK_ROOT="$SDK_ROOT/ndk/28.2.13676358"
    else
      NDK_ROOT="$(ls -d "$SDK_ROOT"/ndk/* 2>/dev/null | sort -V | tail -n 1 || true)"
    fi
  fi
fi
if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
  echo "错误：找不到 Android NDK。请设置 ANDROID_NDK_HOME 或在 Android SDK 下安装 NDK。" >&2
  exit 1
fi
echo "==> NDK: $NDK_ROOT"

case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux)  HOST_TAG="linux-x86_64" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
  *) echo "错误：不支持当前 NDK 主机平台。" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CC_PATH="$TOOLCHAIN/aarch64-linux-android21-clang"
# Windows 的 NDK 里不带扩展名的 clang 是 shell 脚本，cargo 无法 exec
# （os error 193）；与 .ps1 同策略优先选 .cmd 包装器。
if [ "$HOST_TAG" = "windows-x86_64" ] && [ -f "$CC_PATH.cmd" ]; then
  CC_PATH="$CC_PATH.cmd"
fi
if [ ! -f "$CC_PATH" ]; then
  echo "错误：在 $TOOLCHAIN 下找不到 aarch64-linux-android21-clang。" >&2
  exit 1
fi

export CC_aarch64_linux_android="$CC_PATH"
export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_PATH"

JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI_DIR"

PROFILE_ARGS=()
if [ "$PROFILE" = "release" ]; then PROFILE_ARGS=(--release); fi

echo "==> cargo build --target aarch64-linux-android ($PROFILE)..."
( cd "$APP_DIR" && cargo build --manifest-path "$MANIFEST" --target aarch64-linux-android "${PROFILE_ARGS[@]}" )

BUILT_SO="$APP_DIR/rust/target/aarch64-linux-android/$PROFILE/libfqapi_core.so"
if [ ! -s "$BUILT_SO" ]; then
  echo "错误：Rust 交叉编译未产出 $BUILT_SO" >&2
  exit 1
fi
cp -f "$BUILT_SO" "$JNI_DIR/libfqapi_core.so"
echo "==> jniLibs: $JNI_DIR/libfqapi_core.so"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$JNI_DIR/libfqapi_core.so"
else
  shasum -a 256 "$JNI_DIR/libfqapi_core.so"
fi

if [ "$HOST_LIB" -eq 1 ]; then
  echo "==> 编译宿主 cdylib..."
  ( cd "$APP_DIR" && cargo build --manifest-path "$MANIFEST" "${PROFILE_ARGS[@]}" )
fi
