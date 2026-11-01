#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
  # Swift 6.4 CLT packages Swift Testing outside the native SwiftPM default search path.
  framework_dir="$developer_dir/Library/Developer/Frameworks"
  plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  swift test --build-system native --disable-xctest \
    -Xswiftc -F -Xswiftc "$framework_dir" \
    -Xswiftc -load-plugin-library -Xswiftc "$plugin" \
    -Xlinker "-F$framework_dir" -Xlinker -rpath -Xlinker "$framework_dir" "$@"
else
  swift test "$@"
fi
