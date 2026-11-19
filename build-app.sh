#!/bin/sh
set -eu
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0
cargo build --locked --release
build_dir="${CARGO_TARGET_DIR:-target}"
bundle="DiskTally.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources" "$build_dir/swift-cache"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$build_dir/swift-cache" \
    -import-objc-header mac/DiskTally.h mac/main.swift mac/Inventory.swift mac/FileMap.swift mac/Treemap.swift mac/Chrome.swift mac/Outline.swift mac/ApplicationMenu.swift mac/Volumes.swift mac/ScanCache.swift mac/TrashReview.swift \
    "$build_dir/release/libdisktally.a" -framework AppKit -framework Foundation \
    -o "$bundle/MacOS/DiskTally"
cp mac/Info.plist "$bundle/Info.plist"
if [ -f mac/AppIcon.icns ]; then cp mac/AppIcon.icns "$bundle/Resources/"; fi
codesign --force --sign - DiskTally.app
