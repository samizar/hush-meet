#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -n "${HUSH_APP_SOURCE:-}" ]]; then
    TASK_APP_SOURCE="${HUSH_APP_SOURCE:A}"
    codesign --verify --deep --strict "$TASK_APP_SOURCE"
else
    ./scripts/build.sh
    TASK_APP_SOURCE="$PWD/build/Hush.app"
fi
TASK_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/hush-dmg.XXXXXX")
trap 'rm -rf "$TASK_STAGE"' EXIT
ditto "$TASK_APP_SOURCE" "$TASK_STAGE/Hush.app"
ln -s /Applications "$TASK_STAGE/Applications"
cp Vendor/Muesli/LICENSE "$TASK_STAGE/Muesli License.txt"
hdiutil create -volname Hush -srcfolder "$TASK_STAGE" -ov -format UDZO build/Hush.dmg
if [[ -n "${HUSH_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$HUSH_SIGN_IDENTITY" build/Hush.dmg
fi
if [[ -n "${HUSH_NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${HUSH_SIGN_IDENTITY:-}" ]]; then print -u2 "Set HUSH_SIGN_IDENTITY before notarizing."; exit 1; fi
    xcrun notarytool submit build/Hush.dmg --keychain-profile "$HUSH_NOTARY_PROFILE" --wait
    xcrun stapler staple build/Hush.dmg
    xcrun stapler validate build/Hush.dmg
fi
shasum -a 256 build/Hush.dmg | sed 's|build/Hush.dmg|Hush.dmg|' > build/Hush.dmg.sha256
print "Packaged $PWD/build/Hush.dmg"
