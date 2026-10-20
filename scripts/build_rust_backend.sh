#!/usr/bin/env bash
# Builds the Rust native core (rust/ -> libfqapi_core.so) for Android
# (arm64-v8a and armeabi-v7a) and copies each library into its
# android/app/src/main/jniLibs/<abi> directory.
#
# Both ABIs are always built: the split APK build packages both (see the
# split-per-ABI build in .github/workflows/android-apk.yml), so building
# only one would leave the packaging verification without the other library
# and fail the build.
# Cargo caches per target, so a rebuild with no Rust changes is fast.
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
#   ./scripts/build_rust_backend.sh --profile=debug
#
# Unknown arguments are a hard error, never silently ignored: a typo such as
# --skip-codege would otherwise build something different from what the caller
# asked for. --profile only accepts release|debug. The NDK must be exactly
# the pinned revision below; any other revision is a hard error, never a
# silent fallback to the newest installed NDK.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"
PINNED_NDK_VERSION="28.2.13676358"

SKIP_CODEGEN=0
HOST_LIB=0
PROFILE=release
usage() {
  echo "Usage: $0 [--skip-codegen] [--host-lib] [--profile <release|debug>|--profile=<release|debug>]" >&2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-codegen) SKIP_CODEGEN=1 ;;
    --host-lib)     HOST_LIB=1 ;;
    --profile)
      if [ "$#" -lt 2 ]; then
        echo "错误：--profile 需要一个取值（release|debug）。" >&2
        usage
        exit 2
      fi
      case "$2" in
        release|debug) PROFILE="$2" ;;
        *) echo "错误：--profile 取值无效：$2（应为 release|debug）。" >&2; exit 2 ;;
      esac
      shift ;;
    --profile=*)
      case "${1#--profile=}" in
        release|debug) PROFILE="${1#--profile=}" ;;
        *) echo "错误：--profile 取值无效：${1#--profile=}（应为 release|debug）。" >&2; exit 2 ;;
      esac ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
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

# Locate the NDK: explicit env first, then the SDK. Only the pinned revision
# is acceptable: falling back to the newest installed NDK (or honouring an env
# override that points elsewhere) would silently change the toolchain the
# release was built with, so any other resolution is a hard error.
NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$NDK_ROOT" ]; then
  SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$SDK_ROOT" ] && [ -f "$APP_DIR/android/local.properties" ]; then
    SDK_ROOT="$(sed -n 's/^sdk\.dir=//p' "$APP_DIR/android/local.properties" | head -n 1)"
  fi
  if [ -n "$SDK_ROOT" ]; then
    NDK_ROOT="$SDK_ROOT/ndk/$PINNED_NDK_VERSION"
  fi
fi
if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
  echo "错误：找不到 Android NDK $PINNED_NDK_VERSION。请设置 ANDROID_NDK_HOME 指向该版本，或在 Android SDK 下安装 NDK $PINNED_NDK_VERSION。" >&2
  exit 1
fi
if [ "$(basename "$NDK_ROOT")" != "$PINNED_NDK_VERSION" ]; then
  echo "错误：解析到的 NDK 不是 pinned 版本 $PINNED_NDK_VERSION（解析到 $NDK_ROOT）。请安装 pinned 版本并指向它，不要用其它版本静默替代。" >&2
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

# Cross-compiles the Rust core for one Android ABI and installs it into
# that ABI's jniLibs directory. Arguments: Rust target triple, NDK clang
# triple (without the API level or -clang suffix), jniLibs ABI directory.
# The armv7 target uses the armv7a NDK triple (armeabi-v7a with NEON, the
# same assumption the Flutter engine build makes for 32-bit ARM).
build_android_target() {
  local rust_target="$1" clang_triple="$2" abi="$3"
  local cc_path="$TOOLCHAIN/${clang_triple}21-clang"
  # Windows 的 NDK 里不带扩展名的 clang 是 shell 脚本，cargo 无法 exec
  # （os error 193）；与 .ps1 同策略优先选 .cmd 包装器。
  if [ "$HOST_TAG" = "windows-x86_64" ] && [ -f "$cc_path.cmd" ]; then
    cc_path="$cc_path.cmd"
  fi
  if [ ! -f "$cc_path" ]; then
    echo "错误：在 $TOOLCHAIN 下找不到 ${clang_triple}21-clang。" >&2
    exit 1
  fi
  local cc_var="CC_${rust_target//-/_}"
  local ar_var="AR_${rust_target//-/_}"
  # Uppercase via tr: ${var^^} needs bash 4+, but macOS ships bash 3.2.
  local linker_var
  linker_var="$(printf '%s' "CARGO_TARGET_${rust_target//-/_}_LINKER" | tr 'a-z' 'A-Z')"
  export "$cc_var=$cc_path"
  export "$ar_var=$TOOLCHAIN/llvm-ar"
  export "$linker_var=$cc_path"

  local jni_dir="$APP_DIR/android/app/src/main/jniLibs/$abi"
  mkdir -p "$jni_dir"

  local profile_args=()
  if [ "$PROFILE" = "release" ]; then profile_args=(--release); fi

  echo "==> cargo build --target $rust_target ($PROFILE)..."
  ( cd "$APP_DIR" && cargo build --manifest-path "$MANIFEST" --target "$rust_target" "${profile_args[@]}" )

  local built_so="$APP_DIR/rust/target/$rust_target/$PROFILE/libfqapi_core.so"
  if [ ! -s "$built_so" ]; then
    echo "错误：Rust 交叉编译未产出 $built_so" >&2
    exit 1
  fi
  cp -f "$built_so" "$jni_dir/libfqapi_core.so"
  echo "==> jniLibs: $jni_dir/libfqapi_core.so"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$jni_dir/libfqapi_core.so"
  else
    shasum -a 256 "$jni_dir/libfqapi_core.so"
  fi
}

build_android_target aarch64-linux-android aarch64-linux-android arm64-v8a
build_android_target armv7-linux-androideabi armv7a-linux-androideabi armeabi-v7a

if [ "$HOST_LIB" -eq 1 ]; then
  echo "==> 编译宿主 cdylib..."
  ( cd "$APP_DIR" && cargo build --manifest-path "$MANIFEST" "${PROFILE_ARGS[@]}" )
fi
