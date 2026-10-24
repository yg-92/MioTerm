#!/usr/bin/env bash
# 生成可以直接拷到其他 Apple Silicon Mac 的发行包：
#   1. 构建 arm64 版 MioTerm.app；
#   2. 复制一份 App，去掉本机扩展属性并改成临时签名，
#      避免接收方的 Gatekeeper 去校验一个它并不认识的本机证书；
#   3. 连同首次打开说明打成一个 zip。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-app.sh"

APP="$ROOT/build/MioTerm.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
NAME="MioTerm-${VERSION}-macOS-arm64"
DIST_PARENT="$ROOT/build/dist"
DIST_DIR="$DIST_PARENT/$NAME"
ZIP="$DIST_PARENT/$NAME.zip"

mkdir -p "$DIST_PARENT"
# 只清理本脚本生成的同名目录，避免旧包里的文件混进新包。
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto "$APP" "$DIST_DIR/MioTerm.app"
xattr -cr "$DIST_DIR/MioTerm.app"
codesign --force --sign - "$DIST_DIR/MioTerm.app"
codesign --verify --deep --strict --verbose=2 "$DIST_DIR/MioTerm.app"

ARCH_LIST="$(lipo -archs "$DIST_DIR/MioTerm.app/Contents/MacOS/MioTerm")"
if [[ "$ARCH_LIST" != *arm64* ]]; then
  echo "错误：发行包不是 arm64 可执行文件（$ARCH_LIST）。" >&2
  exit 1
fi

cp "$ROOT/Resources/首次打开说明.txt" "$DIST_DIR/README.txt"

rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$DIST_DIR" "$ZIP"

echo "发行包：$ZIP"
echo "版本：$VERSION（build $BUILD_NUMBER） · 架构：$ARCH_LIST"
shasum -a 256 "$ZIP" | awk '{print "SHA-256：" $1}'
echo "提示：临时签名未经过 Apple 公证，接收方首次打开需按“README.txt”放行一次。"
