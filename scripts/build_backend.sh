#!/usr/bin/env bash
# 从  源码编译当前宿主平台的后端，并同步运行时文件到 fqapp。
#
# 仓库里不含后端二进制（体积大且可由源码重建）。Android 构建必须加 --jni，
# assets/bin/ 中的宿主可执行文件仅供桌面环境使用。
#
# 用法：
#   ./scripts/build_backend.sh                  # 默认把 ../ 当作源码目录
#   ./scripts/build_backend.sh /path/to/   # 手动指定源码目录
#   ./scripts/build_backend.sh --force-config   # 连已有的 config 也拉回上游默认值
#   ./scripts/build_backend.sh --force-runtime  # 显式覆盖已有 Web/过滤器/插件代码
#   ./scripts/build_backend.sh --jni            # 额外编译 liblegacy.so（c-shared, 真 JNI）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

FORCE_CONFIG=0
FORCE_RUNTIME=0
BUILD_JNI=0
SRC_ARG=""
for arg in "$@"; do
  case "$arg" in
    --force-config) FORCE_CONFIG=1 ;;
    --force-runtime) FORCE_RUNTIME=1 ;;
    --jni)         BUILD_JNI=1 ;;
    *)             SRC_ARG="$arg" ;;
  esac
done
LEGACY_DIR="${SRC_ARG:-$(dirname "$APP_DIR")/}"

if ! command -v go >/dev/null 2>&1; then
  echo "错误：未找到 go 命令，请先安装 Go 1.26+ 并加入 PATH。" >&2
  exit 1
fi

if [ ! -f "$LEGACY_DIR/main.go" ] || [ ! -f "$LEGACY_DIR/go.mod" ]; then
  echo "错误：$LEGACY_DIR 看起来不是  源码目录（缺少 main.go / go.mod）。" >&2
  echo "用法：$0 [--force-config] [ 源码目录]" >&2
  exit 1
fi

echo "==> 源码目录: $LEGACY_DIR"
HOST_GOOS="$(go env GOHOSTOS)"
HOST_GOARCH="$(go env GOHOSTARCH)"
if [ -z "$HOST_GOOS" ] || [ -z "$HOST_GOARCH" ]; then
  echo "错误：无法确定 Go 宿主平台。" >&2
  exit 1
fi
echo "==> 编译宿主后端 ($HOST_GOOS/$HOST_GOARCH, CGO_ENABLED=0)..."
mkdir -p "$APP_DIR/assets/bin"

OUT_BIN="$APP_DIR/assets/bin/"
BUILD_BIN="$(mktemp "$APP_DIR/assets/bin/..XXXXXXXX")"
BUILD_SO=""
BUILD_SO_DIR=""
cleanup_build() {
  rm -f "$BUILD_BIN"
  if [ -n "$BUILD_SO" ]; then rm -f "$BUILD_SO" "${BUILD_SO%.so}.h"; fi
  if [ -n "$BUILD_SO_DIR" ]; then rmdir "$BUILD_SO_DIR"; fi
}
trap cleanup_build EXIT

# Git Bash / MSYS2 does NOT translate POSIX paths for native Windows programs.
# Handing go a path like "/e/foo" makes Windows resolve it against the current
# drive, so the binary silently lands in "E:\e\foo" while go still exits 0.
# Keep two variables: GO_OUT for go (Windows form), OUT_BIN for bash checks.
GO_OUT="$BUILD_BIN"
if command -v cygpath >/dev/null 2>&1; then
  GO_OUT="$(cygpath -w "$BUILD_BIN")"
fi

( cd "$LEGACY_DIR" && \
  GOOS="$HOST_GOOS" GOARCH="$HOST_GOARCH" CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$GO_OUT" . )

# Never trust go's exit code alone: it can be 0 with no file produced, which is
# exactly how the path-mangling bug above looks from the outside.
if [ ! -s "$BUILD_BIN" ]; then
  echo "错误：编译未产出 $OUT_BIN" >&2
  echo "      go build 返回 0，但文件缺失或为空。" >&2
  echo "      传给 go 的输出路径是：$GO_OUT" >&2
  exit 1
fi
mv -f "$BUILD_BIN" "$OUT_BIN"

echo "==> 同步运行时文件..."
mkdir -p "$APP_DIR/assets/config" "$APP_DIR/assets/filters" \
         "$APP_DIR/assets/web" "$APP_DIR/assets/plugins"

# assets/config 是 App 侧的运行时配置，不是代码：只做首次播种，已存在的一概不覆盖。
#
# 这里有针对移动端刻意调整过的值。典型是 anti_crawler.enabled，它只影响未命中
# 路由的处理（/internal/endpoints/router.go）：true 会把未知路径 302 跳到
# redirect_url，false 则返回 JSON 404。上游  面向 Web UI 所以默认 true，
# 但 App 的 ApiClient 收到 302 只会报出莫名其妙的错误，因此这里必须保持 false。
# 需要拉回上游默认值时，删掉对应文件再跑脚本，或加 --force-config。
sync_config() {
  local name="$1"
  local dst="$APP_DIR/assets/config/$name"
  if [ -f "$dst" ] && [ "$FORCE_CONFIG" -eq 0 ]; then
    echo "    保留 $name（已存在，跳过同步）"
    return
  fi
  cp "$LEGACY_DIR/config/$name" "$dst"
  echo "    写入 $name"
}

# 只同步这三个确定文件，绝不整目录复制 config/：
# 真实设备池 device_pool.json 含 secret_key，打进 APK 等于泄露设备凭据。
sync_config config.json
sync_config filter.json
sync_config device_pool.example.json
rm -f "$APP_DIR/assets/config/device_pool.json"

# Copy only missing entries without cp -n: newer GNU cp can report a skipped
# existing file as an error, while BSD cp and older GNU cp return success.
# Walk directories explicitly so existing app fixes and missing nested files
# have the same behavior on Linux, macOS, and Git Bash. A real copy/mkdir
# failure still stops the build.
copy_missing_tree() (
  local src="$1" dst="$2" entry target
  if [ ! -d "$src" ]; then
    echo "错误：运行时源码目录不存在：$src" >&2
    return 1
  fi
  mkdir -p "$dst" || return
  shopt -s dotglob nullglob
  for entry in "$src"/*; do
    target="$dst/${entry##*/}"
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      if { [ -e "$target" ] || [ -L "$target" ]; } &&
         { [ ! -d "$target" ] || [ -L "$target" ]; }; then
        echo "错误：运行时目标路径不是可同步的目录：$target" >&2
        return 1
      fi
      copy_missing_tree "$entry" "$target" || return
    elif [ ! -e "$target" ] && [ ! -L "$target" ]; then
      cp -RP "$entry" "$target" || return
    fi
  done
)

# 保留 App 仓库中的修复。只有显式 --force-runtime 才用上游代码覆盖。
for name in filters web plugins; do
  if [ "$FORCE_RUNTIME" -eq 1 ]; then
    cp -R "$LEGACY_DIR/$name/." "$APP_DIR/assets/$name/"
  else
    copy_missing_tree "$LEGACY_DIR/$name" "$APP_DIR/assets/$name"
  fi
done
echo "    已同步 filters/ web/ plugins/（默认保留已有文件）"

echo "==> 完成。"
ls -l "$OUT_BIN"

if [ "$BUILD_JNI" -eq 1 ]; then
  echo
  echo "==> 编译 liblegacy.so (c-shared, android/arm64, CGO_ENABLED=1)..."

  JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"
  mkdir -p "$JNI_DIR"
  SO_OUT="$JNI_DIR/liblegacy.so"

  # c-shared 需要 cgo + NDK clang。用 CGO_CFLAGS 指向 NDK sysroot 找 jni.h。
  # NDK 版本可能不同机器不一样，这里用环境变量或自动探测。
  NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [ -z "$NDK_ROOT" ]; then
    # 尝试从 SDK 推断
    for d in "${ANDROID_HOME:-}"/ndk/* "${ANDROID_SDK_ROOT:-}"/ndk/* /c/android-sdk/ndk/*; do
      if [ -d "$d" ]; then NDK_ROOT="$d"; fi
    done
  fi
  if [ -z "$NDK_ROOT" ]; then
    echo "错误：找不到 NDK。请设 ANDROID_NDK_HOME 环境变量。" >&2
    exit 1
  fi
  if command -v cygpath >/dev/null 2>&1; then NDK_ROOT="$(cygpath -u "$NDK_ROOT")"; fi
  echo "    NDK: $NDK_ROOT"

  case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    Linux) HOST_TAG="linux-x86_64" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
    *) echo "错误：不支持当前 NDK 主机平台。" >&2; exit 1 ;;
  esac
  TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
  CC_PATH="$TOOLCHAIN/aarch64-linux-android21-clang"
  if [ ! -f "$CC_PATH" ]; then CC_PATH="$TOOLCHAIN/aarch64-linux-android21-clang.cmd"; fi
  if [ ! -f "$CC_PATH" ]; then
    echo "错误：在 $TOOLCHAIN 下找不到 aarch64 clang。" >&2
    exit 1
  fi

  SYSROOT=$(cd "$TOOLCHAIN/.." && pwd)/sysroot
  if [ ! -d "$SYSROOT" ]; then
    echo "错误：NDK sysroot 不存在：$SYSROOT" >&2
    exit 1
  fi

  BUILD_SO_DIR="$(mktemp -d "$JNI_DIR/.-build.XXXXXXXX")"
  BUILD_SO="$BUILD_SO_DIR/liblegacy.so"
  GO_SO="$BUILD_SO"
  if command -v cygpath >/dev/null 2>&1; then
    GO_SO="$(cygpath -w "$BUILD_SO")"
  fi
  CC_WIN="$CC_PATH"
  if command -v cygpath >/dev/null 2>&1; then
    CC_WIN="$(cygpath -m "$CC_PATH")"
  fi
  SYSROOT_WIN="$SYSROOT"
  if command -v cygpath >/dev/null 2>&1; then
    SYSROOT_WIN="$(cygpath -m "$SYSROOT")"
  fi

  echo "    CC: $CC_WIN"
  echo "    sysroot: $SYSROOT_WIN"

  ( cd "$LEGACY_DIR" && \
    CC="\"$CC_WIN\"" \
    CGO_CFLAGS="-I\"$SYSROOT_WIN/usr/include\"" \
    GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
    go build -buildmode=c-shared -trimpath -ldflags "-s -w" -o "$GO_SO" . )

  if [ ! -s "$BUILD_SO" ]; then
    echo "错误：liblegacy.so 未产出。" >&2
    exit 1
  fi
  mv -f "$BUILD_SO" "$SO_OUT"

  # Go emits a companion C header next to a c-shared output. Kotlin does not
  # consume it, so keep the Android source tree focused on the .so itself.
  rm -f "${BUILD_SO%.so}.h"

  echo "    产出:"
  ls -l "$SO_OUT"
  echo
  echo "注意：c-shared 编译（含 cgo）首次会很慢（10-20 分钟），后续有缓存会快。"
else
  echo
  echo "提示：加 --jni 可同时编译 liblegacy.so（JNI 模式，解决 SELinux 阻塞）。"
fi
