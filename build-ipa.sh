#!/bin/bash
# Build an UNSIGNED .ipa. Sign it yourself with your sideloading tool.
#
#   ./build-ipa.sh            # Release
#   ./build-ipa.sh Debug
#
# Requires macOS with Xcode and xcodegen. Run ./build-ios.sh first whenever
# rust-core/ changes, so AirliftFFI.xcframework is up to date.
set -euo pipefail

CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="AirliftSilence"

if [ ! -d "$ROOT/AirliftFFI.xcframework" ]; then
    echo "Error: AirliftFFI.xcframework is missing — run ./build-ios.sh first." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building $APP_NAME ($CONFIG)..."
rm -rf build/DerivedData build/Payload build/*.app build/*.ipa
mkdir -p build

xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

APP_PATH="$(find build/DerivedData/Build/Products -name "$APP_NAME.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_NAME.app not found in DerivedData" >&2
    exit 1
fi

echo "==> Packaging IPA..."
cp -R "$APP_PATH" "build/$APP_NAME.app"
rm -rf "build/$APP_NAME.app/_CodeSignature"
rm -rf "build/$APP_NAME.app/embedded.mobileprovision"

mkdir -p build/Payload
cp -R "build/$APP_NAME.app" "build/Payload/$APP_NAME.app"

cd build
zip -qr "$APP_NAME.ipa" Payload
rm -rf Payload "$APP_NAME.app"

echo "==> Done: $ROOT/build/$APP_NAME.ipa"
ls -lh "$ROOT/build/$APP_NAME.ipa"
