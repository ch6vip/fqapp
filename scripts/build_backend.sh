#!/usr/bin/env bash
# 从  源码交叉编译 Android 版后端二进制，并同步运行时文件到 fqapp。
#
# 仓库里不含后端二进制（体积大且可由源码重建），clone 后必须先跑这个脚本，
# 否则打出的 APK 会因为缺少 assets/bin/ 而无法启动本地服务。
#
# 用法：
#   ./scripts/build_backend.sh                  # 默认把 ../ 当作源码目录
#   ./scripts/build_backend.sh /path/to/   # 手动指定源码目录
#   ./scripts/build_backend.sh --force-config   # 连已有的 config 也拉回上游默认值
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

FORCE_CONFIG=0
SRC_ARG=""
for arg in "$@"; do
  case "$arg" in
    --force-config) FORCE_CONFIG=1 ;;
    *)              SRC_ARG="$arg" ;;
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
echo "==> 交叉编译后端 (android/arm64, CGO_ENABLED=0)..."
mkdir -p "$APP_DIR/assets/bin"

OUT_BIN="$APP_DIR/assets/bin/"

# Git Bash / MSYS2 does NOT translate POSIX paths for native Windows programs.
# Handing go a path like "/e/foo" makes Windows resolve it against the current
# drive, so the binary silently lands in "E:\e\foo" while go still exits 0.
# Keep two variables: GO_OUT for go (Windows form), OUT_BIN for bash checks.
GO_OUT="$OUT_BIN"
if command -v cygpath >/dev/null 2>&1; then
  GO_OUT="$(cygpath -w "$OUT_BIN")"
fi

( cd "$LEGACY_DIR" && \
  GOOS=android GOARCH=arm64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$GO_OUT" . )

# Never trust go's exit code alone: it can be 0 with no file produced, which is
# exactly how the path-mangling bug above looks from the outside.
if [ ! -s "$OUT_BIN" ]; then
  echo "错误：编译未产出 $OUT_BIN" >&2
  echo "      go build 返回 0，但文件缺失或为空。" >&2
  echo "      传给 go 的输出路径是：$GO_OUT" >&2
  exit 1
fi

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

# filters / web / plugins 是代码而非配置，每次都覆盖。
cp -r "$LEGACY_DIR"/filters/.  "$APP_DIR/assets/filters/"
cp -r "$LEGACY_DIR"/web/.      "$APP_DIR/assets/web/"
cp -r "$LEGACY_DIR"/plugins/.  "$APP_DIR/assets/plugins/"
echo "    覆盖 filters/ web/ plugins/"

echo "==> 完成。"
ls -l "$OUT_BIN"
echo
echo "注意：android/app/src/main/jniLibs/ 下的 liblegacy.so 不在本仓库内。"
echo "      它是 JNI 方案的占位文件（当前并不包含 JNI 导出符号），"
echo "      且 jniLibs 尚未被 MainActivity 加载，不生成也不影响 debug 构建。"
