#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
TASK_APP="$PWD/build/Hush.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Hush "$TASK_APP/Contents/MacOS/Hush"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
cp Vendor/Muesli/LICENSE "$TASK_APP/Contents/Resources/Muesli-LICENSE.txt"
cp Resources/PrivacyInfo.xcprivacy "$TASK_APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ -f Resources/Hush.icns ]]; then cp Resources/Hush.icns "$TASK_APP/Contents/Resources/Hush.icns"; fi
if [[ -n "${HUSH_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/Hush.entitlements --sign "$HUSH_SIGN_IDENTITY" "$TASK_APP"
else
    codesign --force --options runtime --entitlements Resources/Hush.entitlements --sign - "$TASK_APP"
fi
codesign --verify --deep --strict "$TASK_APP"
print "Built $TASK_APP"
