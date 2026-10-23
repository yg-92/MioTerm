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

# 用固定的自签名身份打包，避免每次重建都因 ad-hoc 签名的 cdhash 变化
# 而让 macOS 重新弹出“输入钥匙串密码”的授权框。
SIGN_KEYCHAIN="${MIOTERM_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/mioterm-signing.keychain-db}"
SIGN_PASSWORD_FILE="$HOME/Library/Application Support/MioTerm/signing/keychain-password"
IDENTITY="${MIOTERM_SIGNING_IDENTITY:-MioTerm Code Signing}"

if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
  "$ROOT/scripts/create-signing-identity.sh" >/dev/null
fi

SIGNED=0
if [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_PASSWORD_FILE" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_PASSWORD_FILE")" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
  # codesign 只会去钥匙串搜索列表里找身份：临时加上，签完立刻还原，
  # 不给其他程序留下一个会弹解锁框的钥匙串。
  ORIGINAL_KEYCHAINS=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    ORIGINAL_KEYCHAINS+=("$line")
  done < <(security list-keychains -d user)
  restore_keychains() {
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null
  }
  trap restore_keychains EXIT
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$SIGN_KEYCHAIN"
  if codesign --force --sign "$IDENTITY" --keychain "$SIGN_KEYCHAIN" --timestamp=none "$APP" 2>/dev/null \
    || codesign --force --sign "$IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"; then
    SIGNED=1
  fi
  restore_keychains
  trap - EXIT
fi

if [[ "$SIGNED" -eq 0 ]]; then
  codesign --force --deep --sign - "$APP"
fi

echo "构建完成：$APP"
