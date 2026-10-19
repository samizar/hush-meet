#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
TASK_APP="$PWD/build/Hush.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Hush "$TASK_APP/Contents/MacOS/Hush"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
cp Vendor/Muesli/LICENSE "$TASK_APP/Contents/Resources/Muesli-LICENSE.txt"
cp Vendor/Sparkle-LICENSE.txt "$TASK_APP/Contents/Resources/Sparkle-LICENSE.txt"
cp Resources/PrivacyInfo.xcprivacy "$TASK_APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ -f Resources/Hush.icns ]]; then cp Resources/Hush.icns "$TASK_APP/Contents/Resources/Hush.icns"; fi
TASK_ASSETS_PLIST=$(mktemp "${TMPDIR:-/tmp}/hush-assets.XXXXXX")
xcrun actool Resources/Assets.xcassets --compile "$TASK_APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --accent-color AccentColor --output-partial-info-plist "$TASK_ASSETS_PLIST" > /dev/null
rm -f "$TASK_ASSETS_PLIST"
TASK_SPARKLE=(.build/artifacts/**/Sparkle.framework(N/))
if (( ${#TASK_SPARKLE} != 1 )); then print -u2 'Expected one resolved Sparkle framework.'; exit 1; fi
mkdir -p "$TASK_APP/Contents/Frameworks"
ditto "$TASK_SPARKLE[1]" "$TASK_APP/Contents/Frameworks/Sparkle.framework"
TASK_FRAMEWORK="$TASK_APP/Contents/Frameworks/Sparkle.framework"
TASK_IDENTITY="${HUSH_SIGN_IDENTITY:--}"
TASK_TIMESTAMP=()
if [[ "$TASK_IDENTITY" != '-' ]]; then TASK_TIMESTAMP=(--timestamp); fi
codesign --force --options runtime "${TASK_TIMESTAMP[@]}" --sign "$TASK_IDENTITY" "$TASK_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime "${TASK_TIMESTAMP[@]}" --preserve-metadata=entitlements --sign "$TASK_IDENTITY" "$TASK_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime "${TASK_TIMESTAMP[@]}" --sign "$TASK_IDENTITY" "$TASK_FRAMEWORK/Versions/B/Autoupdate"
codesign --force --options runtime "${TASK_TIMESTAMP[@]}" --sign "$TASK_IDENTITY" "$TASK_FRAMEWORK/Versions/B/Updater.app"
codesign --force --options runtime "${TASK_TIMESTAMP[@]}" --sign "$TASK_IDENTITY" "$TASK_FRAMEWORK"
codesign --force --options runtime "${TASK_TIMESTAMP[@]}" --entitlements Resources/Hush.entitlements --sign "$TASK_IDENTITY" "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
print "Built $TASK_APP"
