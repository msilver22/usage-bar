#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_flags=()
toolchain_usr="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
testing_plugins="$toolchain_usr/lib/swift/host/plugins/testing"
# Swift 6.4 Command Line Tools omit the bundled Testing plugin from the default search path.
if [[ -d "$testing_plugins" ]]; then
    test_flags=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
fi
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "${test_flags[@]}"
