#!/usr/bin/env bash
# 从  源码交叉编译 Android 版后端二进制，并同步运行时文件到 fqapp。
#
# 仓库里不含后端二进制（体积大且可由源码重建），clone 后必须先跑这个脚本，
# 否则打出的 APK 会因为缺少 assets/bin/ 而无法启动本地服务。
#
# 用法：
#   ./scripts/build_backend.sh                  # 默认把 ../ 当作源码目录
#   ./scripts/build_backend.sh /path/to/   # 手动指定源码目录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
LEGACY_DIR="${1:-$(dirname "$APP_DIR")/}"

if ! command -v go >/dev/null 2>&1; then
  echo "错误：未找到 go 命令，请先安装 Go 1.26+ 并加入 PATH。" >&2
  exit 1
fi

if [ ! -f "$LEGACY_DIR/main.go" ] || [ ! -f "$LEGACY_DIR/go.mod" ]; then
  echo "错误：$LEGACY_DIR 看起来不是  源码目录（缺少 main.go / go.mod）。" >&2
  echo "用法：$0 < 源码目录>" >&2
  exit 1
fi

echo "==> 源码目录: $LEGACY_DIR"
echo "==> 交叉编译后端 (android/arm64, CGO_ENABLED=0)..."
mkdir -p "$APP_DIR/assets/bin"
( cd "$LEGACY_DIR" && \
  GOOS=android GOARCH=arm64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$APP_DIR/assets/bin/" . )

echo "==> 同步运行时文件..."
mkdir -p "$APP_DIR/assets/config" "$APP_DIR/assets/filters" \
         "$APP_DIR/assets/web" "$APP_DIR/assets/plugins"

# 只同步这几个确定的配置文件。真实设备池含 secret_key，绝不能打进 APK，
# 所以这里显式拷贝 example 版本，不整目录复制。
cp "$LEGACY_DIR/config/config.json"                "$APP_DIR/assets/config/config.json"
cp "$LEGACY_DIR/config/filter.json"                "$APP_DIR/assets/config/filter.json"
cp "$LEGACY_DIR/config/device_pool.example.json"   "$APP_DIR/assets/config/device_pool.example.json"
rm -f "$APP_DIR/assets/config/device_pool.json"

cp -r "$LEGACY_DIR"/filters/.  "$APP_DIR/assets/filters/"
cp -r "$LEGACY_DIR"/web/.      "$APP_DIR/assets/web/"
cp -r "$LEGACY_DIR"/plugins/.  "$APP_DIR/assets/plugins/"

echo "==> 完成。"
ls -l "$APP_DIR/assets/bin/"
echo
echo "注意：android/app/src/main/jniLibs/ 下的 liblegacy.so 不在本仓库内。"
echo "      它是 JNI 方案的占位文件（当前并不包含 JNI 导出符号），"
echo "      且 jniLibs 尚未被 MainActivity 加载，不生成也不影响 debug 构建。"
