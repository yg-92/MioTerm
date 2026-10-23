#!/usr/bin/env bash
# 建一个固定的自签名代码签名身份，专供 MioTerm 本地打包使用。
#
# 为什么需要它：ad-hoc 签名的 cdhash 每次重建都会变，Keychain 里存的授权
# 只认旧哈希，于是每跑一次新构建，读一次已保存的口令就会弹一次系统密码框。
# 换成固定证书后，授权只认证书与标识，重建不再影响。
#
# 私钥放在独立的钥匙串里，密码只在本机保存（0600），不碰用户的登录钥匙串，
# 也不会被加进全局搜索列表。
set -euo pipefail

KEYCHAIN="${MIOTERM_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/mioterm-signing.keychain-db}"
STATE_DIR="${MIOTERM_SIGNING_STATE:-$HOME/Library/Application Support/MioTerm/signing}"
PASSWORD_FILE="$STATE_DIR/keychain-password"
IDENTITY="${MIOTERM_SIGNING_IDENTITY:-MioTerm Code Signing}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
if [[ ! -f "$PASSWORD_FILE" ]]; then
  umask 077
  openssl rand -base64 32 > "$PASSWORD_FILE"
fi
chmod 600 "$PASSWORD_FILE"
PASSWORD="$(cat "$PASSWORD_FILE")"

# 自签名证书永远不是“valid identity”（没有受信任的根），这里按存在性判断。
if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" 2>/dev/null || true
  if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "签名身份已存在：$KEYCHAIN"
    exit 0
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

# 显式用 3DES/SHA1：macOS 的 Security 导入器不认 OpenSSL 3 默认的
# AES-256 + SHA256 组合，会误报 “MAC verification failed”。
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$IDENTITY" -passout "pass:$PASSWORD" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
# -T 让 codesign 直接使用这把私钥，不必再弹“codesign 想使用钥匙串中的密钥”。
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "已创建签名身份：$IDENTITY（$KEYCHAIN）"
