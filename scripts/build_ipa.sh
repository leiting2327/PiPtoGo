#!/usr/bin/env bash
# PiPtoGo 构建脚本：在 macOS + Xcode 环境下生成 IPA。
# - 提供了 CERTIFICATE_BASE64 / P12_PASSWORD / PROVISIONING_PROFILE_BASE64 时执行真机签名
# - 未提供时回退为无签名构建，产出 PiPtoGo-unsigned.ipa
set -euo pipefail

cd "$(dirname "$0")/.."

APP="PiPtoGo"
BUNDLE_ID="com.piptogo.app"
BUILD_DIR="build"
SIGNED="0"

echo "==> 生成 Xcode 工程（XcodeGen）"
xcodegen generate

mkdir -p "$BUILD_DIR"

# ---------- 签名材料（可选） ----------
CERT_B64="${CERTIFICATE_BASE64:-}"
P12_PASS="${P12_PASSWORD:-}"
PROFILE_B64="${PROVISIONING_PROFILE_BASE64:-}"

if [[ -n "$CERT_B64" && -n "$PROFILE_B64" ]]; then
    echo "==> 检测到签名材料，执行真机签名"
    SIGNED="1"

    # 1) 证书导入临时钥匙串
    KEYCHAIN="$BUILD_DIR/pip.keychain"
    echo "$CERT_B64" | base64 --decode > "$BUILD_DIR/cert.p12"
    security create-keychain -p tmp "$KEYCHAIN" >/dev/null 2>&1 || true
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p tmp "$KEYCHAIN"
    security import "$BUILD_DIR/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -k tmp "$KEYCHAIN" >/dev/null
    security list-keychains -s "$KEYCHAIN"
    security default-keychain -s "$KEYCHAIN"

    # 2) 安装描述文件并读取元信息
    echo "$PROFILE_B64" | base64 --decode > "$BUILD_DIR/profile.mobileprovision"
    security cms -D -i "$BUILD_DIR/profile.mobileprovision" -o "$BUILD_DIR/profile.plist" >/dev/null
    PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$BUILD_DIR/profile.plist")"
    PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$BUILD_DIR/profile.plist")"
    TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$BUILD_DIR/profile.plist" 2>/dev/null || echo '')"
    GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$BUILD_DIR/profile.plist" 2>/dev/null || echo 'false')"
    mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
    cp "$BUILD_DIR/profile.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"

    if [[ "$GET_TASK_ALLOW" == "true" ]]; then
        CODE_SIGN_IDENTITY="Apple Development"
        EXPORT_METHOD="${EXPORT_METHOD:-development}"
    else
        CODE_SIGN_IDENTITY="iPhone Distribution"
        EXPORT_METHOD="${EXPORT_METHOD:-app-store-connect}"
    fi
    echo "    描述文件: $PROFILE_NAME | Team: $TEAM_ID | 方式: $EXPORT_METHOD"

    # 3) Archive（手动签名）
    xcodebuild archive \
        -project "$APP.xcodeproj" \
        -scheme "$APP" \
        -configuration Release \
        -archivePath "$BUILD_DIR/$APP.xcarchive" \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
        DEVELOPMENT_TEAM="$TEAM_ID"

    # 4) Export IPA
    cat > "$BUILD_DIR/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>$EXPORT_METHOD</string>
	<key>signingStyle</key><string>manual</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key><string>$PROFILE_NAME</string>
	</dict>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/$APP.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
        -exportPath "$BUILD_DIR/export" \
        -allowProvisioningUpdates

    IPA="$(find "$BUILD_DIR/export" -name '*.ipa' | head -1)"
    cp "$IPA" "$BUILD_DIR/$APP.ipa"
    echo "==> 签名 IPA 已生成: $BUILD_DIR/$APP.ipa"
else
    echo "==> 未提供签名材料，生成无签名 IPA"
    xcodebuild archive \
        -project "$APP.xcodeproj" \
        -scheme "$APP" \
        -configuration Release \
        -archivePath "$BUILD_DIR/$APP.xcarchive" \
        -destination 'generic/platform=iOS' \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

    APP_PATH="$(find "$BUILD_DIR/$APP.xcarchive/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
    mkdir -p "$BUILD_DIR/unsigned/Payload"
    cp -R "$APP_PATH" "$BUILD_DIR/unsigned/Payload/"
    (cd "$BUILD_DIR/unsigned" && zip -qry ../$APP-unsigned.ipa Payload)
    echo "==> 无签名 IPA 已生成: $BUILD_DIR/$APP-unsigned.ipa"
fi

echo "==> 构建完成"
