#!/usr/bin/env bash
# 构建指定架构的发行包；ARCH=arm64 或 ARCH=x86_64。
# 应用和归档按架构分开存放，覆盖旧产物前移入本机垃圾桶。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|aarch64) ARCH=arm64 ;;
  x64|amd64|x86_64) ARCH=x86_64 ;;
  *) echo "不支持的架构：$ARCH（可选 arm64、x86_64）" >&2; exit 1 ;;
esac
ARCH_BUILD_DIR="$ROOT/build/$ARCH"
ARCH="$ARCH" BUILD_DIR="$ARCH_BUILD_DIR" "$ROOT/scripts/build-app.sh"

APP="$ARCH_BUILD_DIR/MioTerm.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
NAME="MioTerm-${VERSION}-macOS-${ARCH}"
DIST_PARENT="$ROOT/build/dist"
DIST_DIR="$DIST_PARENT/$NAME"
ZIP="$DIST_PARENT/$NAME.zip"

mkdir -p "$DIST_PARENT"
move_to_trash() {
  if [[ -e "$1" ]]; then
    mkdir -p "$HOME/.Trash"
    mv "$1" "$HOME/.Trash/$(basename "$1")-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  fi
}
move_to_trash "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto "$APP" "$DIST_DIR/MioTerm.app"
xattr -cr "$DIST_DIR/MioTerm.app"
codesign --force --sign - "$DIST_DIR/MioTerm.app"
codesign --verify --deep --strict --verbose=2 "$DIST_DIR/MioTerm.app"

ARCH_LIST="$(lipo -archs "$DIST_DIR/MioTerm.app/Contents/MacOS/MioTerm")"
if [[ "$ARCH_LIST" != "$ARCH" ]]; then
  echo "错误：期望 $ARCH 可执行文件，实际为 $ARCH_LIST。" >&2
  exit 1
fi

cp "$ROOT/Resources/首次打开说明.txt" "$DIST_DIR/README.txt"
cp "$ROOT/LICENSE" "$DIST_DIR/LICENSE"
cp "$ROOT/DESCRIPTION.md" "$DIST_DIR/项目简介.txt"

move_to_trash "$ZIP"
ditto -c -k --norsrc --keepParent "$DIST_DIR" "$ZIP"

echo "发行包：$ZIP"
echo "版本：${VERSION}（build ${BUILD_NUMBER}） · 架构：${ARCH_LIST}"
shasum -a 256 "$ZIP" | awk '{print "SHA-256：" $1}'
echo "提示：临时签名未经过 Apple 公证，接收方首次打开需按“README.txt”放行一次。"
