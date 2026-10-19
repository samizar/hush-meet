#!/bin/zsh
# Builds Hush and opens it with in-memory sample meetings. Nothing is recorded or saved.
# Ad-hoc builds can't load Sparkle under the hardened runtime, so this copy is re-signed without it.
# Usage: ./scripts/preview.sh [--dark] [--reduce-motion] [--demo-meeting] [--demo-failure]
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh > /dev/null
APP="$PWD/build/Hush.app"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
            "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
  codesign --force --sign - "$item" 2> /dev/null
done
codesign --force --entitlements Resources/Hush.entitlements --sign - "$APP" 2> /dev/null
open -n "$APP" --args --demo "$@"
print "Preview running. Quit it from its menu bar icon (… → Quit Hush)."
