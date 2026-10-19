#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bin_dir="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
app="dist/UsageBar.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/UsageBar" "$app/Contents/MacOS/UsageBar"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $PWD/$app"
