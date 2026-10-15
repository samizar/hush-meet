#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TASK_SPARKLE_VERSION=2.10.0
if [[ ! -x build/Sparkle/bin/generate_appcast ]]; then
    mkdir -p build/Sparkle
    gh release download "$TASK_SPARKLE_VERSION" --repo sparkle-project/Sparkle --dir build/Sparkle --pattern "Sparkle-$TASK_SPARKLE_VERSION.tar.xz" --clobber
    TASK_DIGEST=$(shasum -a 256 "build/Sparkle/Sparkle-$TASK_SPARKLE_VERSION.tar.xz" | cut -d ' ' -f 1)
    [[ "$TASK_DIGEST" == c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c ]] || { print -u2 'Sparkle tools checksum mismatch.'; exit 1; }
    tar -xf "build/Sparkle/Sparkle-$TASK_SPARKLE_VERSION.tar.xz" -C build/Sparkle
fi
TASK_ACTUAL=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Sparkle/Sparkle.framework/Resources/Info.plist)
[[ "$TASK_ACTUAL" == "$TASK_SPARKLE_VERSION" ]] || { print -u2 'Unexpected Sparkle tools version.'; exit 1; }
