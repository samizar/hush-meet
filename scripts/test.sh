#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
python3 scripts/audit_network.py
