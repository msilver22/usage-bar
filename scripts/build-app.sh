#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bin_dir="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
app="dist/UsageBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/UsageBar" "$app/Contents/MacOS/UsageBar"
cp -R "$bin_dir/UsageBar_UsageBar.bundle" "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
if remote_url="$(git remote get-url origin 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Add :UsageBarRemoteURL string $remote_url" "$app/Contents/Info.plist"
fi
if git_commit="$(git rev-parse HEAD 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Add :UsageBarGitCommit string $git_commit" "$app/Contents/Info.plist"
fi
if git_upstream="$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Add :UsageBarUpstreamCommit string $git_upstream" "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
echo "Built $PWD/$app"
