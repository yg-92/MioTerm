#!/usr/bin/env bash
# 组装 build/MioTerm.app：SPM 只产出裸可执行文件，.app 结构、Info.plist
# 与签名都在这里手工完成。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="${APP_NAME:-MioTerm}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
TRASH="${HOME}/.Trash"

if [[ -e "$APP" ]]; then
  # 构建产物不直接删除，先挪进系统垃圾桶，避免误覆盖上一次可运行的版本。
  mkdir -p "$TRASH"
  mv "$APP" "$TRASH/${APP_NAME}-$(date +%Y%m%d-%H%M%S).app"
fi

ARCH_FLAGS=()
if [[ "$(uname -m)" == "arm64" ]]; then
  ARCH_FLAGS=(--arch arm64)
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"

BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 有自建签名身份时用固定身份，避免每次重建都因 ad-hoc 签名变化而重新弹出
# Keychain 授权；没有则退回 ad-hoc 签名。
IDENTITY="${MIOTERM_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "MioTerm Code Signing"; then
    IDENTITY="MioTerm Code Signing"
  fi
fi

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp=none \
    --entitlements "$ROOT/Resources/MioTerm.entitlements" "$APP" 2>/dev/null \
    || codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

echo "构建完成：$APP"
