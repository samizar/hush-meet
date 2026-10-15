#!/bin/zsh
# Publish an already signed and notarized DMG, then make its signed feed the latest release.
set -euo pipefail
cd "${0:A:h:h}"
if (( $# != 3 )); then print -u2 'Usage: scripts/publish-release.sh vVERSION final.dmg release-notes.md'; exit 1; fi
TASK_TAG="$1"; TASK_DMG="${2:A}"; TASK_NOTES="${3:A}"
[[ "$TASK_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Use a semantic release tag, such as v1.1.0.'; exit 1; }
[[ -f "$TASK_DMG" && -f "$TASK_NOTES" ]] || { print -u2 'DMG or release notes missing.'; exit 1; }
./scripts/prepare-sparkle.sh
codesign --verify --strict "$TASK_DMG"
xcrun stapler validate "$TASK_DMG"
spctl --assess --type open --context context:primary-signature "$TASK_DMG"
TASK_TEAM=$(codesign -dv --verbose=4 "$TASK_DMG" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$TASK_TEAM" == ZUT6837GB5 ]] || { print -u2 'Unexpected Developer ID team.'; exit 1; }
TASK_REVISION=$(git rev-parse HEAD)
TASK_REMOTE=$(gh api repos/samizar/hush-meet/commits/main --jq .sha)
[[ "$TASK_REMOTE" == "$TASK_REVISION" ]] || { print -u2 'Push the completed source to main before publishing.'; exit 1; }
TASK_PUBLIC=$(build/Sparkle/bin/generate_keys --account app.hush.mac -p)
TASK_EXPECTED=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)
[[ "$TASK_PUBLIC" == "$TASK_EXPECTED" ]] || { print -u2 'The Hush update-signing key is unavailable or does not match. Do not generate a replacement key.'; exit 1; }
TASK_STAGE="$PWD/build/updates/$TASK_TAG"
mkdir -p "$TASK_STAGE"
ditto "$TASK_DMG" "$TASK_STAGE/Hush.dmg"
cp "$TASK_NOTES" "$TASK_STAGE/Hush.md"
if [[ -f Updates/appcast.xml && ! -f "$TASK_STAGE/appcast.xml" ]]; then cp Updates/appcast.xml "$TASK_STAGE/appcast.xml"; fi
build/Sparkle/bin/generate_appcast --account app.hush.mac --maximum-deltas 0 --maximum-versions 3 --embed-release-notes \
    --download-url-prefix "https://github.com/samizar/hush-meet/releases/download/$TASK_TAG/" \
    --link 'https://github.com/samizar/hush-meet/releases' "$TASK_STAGE"
build/Sparkle/bin/sign_update --account app.hush.mac --verify "$TASK_STAGE/appcast.xml"
python3 scripts/validate-update.py "$TASK_STAGE/appcast.xml" "$TASK_STAGE/Hush.dmg" "$TASK_TAG"
(cd "$TASK_STAGE"; shasum -a 256 Hush.dmg > Hush.dmg.sha256)
# Draft first: no client sees a feed until every asset is uploaded successfully.
gh release create "$TASK_TAG" "$TASK_STAGE/Hush.dmg" "$TASK_STAGE/Hush.dmg.sha256" "$TASK_STAGE/appcast.xml" \
    --repo samizar/hush-meet --target "$TASK_REVISION" --title "Hush ${TASK_TAG#v}" --notes-file "$TASK_NOTES" --draft
if [[ "${HUSH_RELEASE_STAGE:-0}" == 1 ]]; then
    gh release edit "$TASK_TAG" --repo samizar/hush-meet --draft=false --prerelease --latest=false
else
    gh release edit "$TASK_TAG" --repo samizar/hush-meet --draft=false --latest
fi
mkdir -p Updates
cp "$TASK_STAGE/appcast.xml" Updates/appcast.xml
print "Published https://github.com/samizar/hush-meet/releases/tag/$TASK_TAG"
