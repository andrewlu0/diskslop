#!/bin/sh
set -eu
cd -P "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0
case "$#:${1:-}" in
    0:|1:--universal) ;;
    *) echo "Usage: ./build-app.sh [--universal]" >&2; exit 2 ;;
esac
identity=${DISKSLOP_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    identities=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
    case "$identities" in
        '') identity=- ;;
        *'
'*) echo "Choose a development certificate with DISKSLOP_SIGN_IDENTITY." >&2; exit 1 ;;
        *) identity=$identities ;;
    esac
fi
if [ "$identity" = "-" ]; then
    echo "Signing ad hoc. macOS may ask for folder access again after a rebuild." >&2
fi
build_dir="${CARGO_TARGET_DIR:-target}"
output_dir="${DISKSLOP_OUTPUT_DIR:-$PWD}"
mkdir -p "$build_dir/swift-cache" "$output_dir"
build_dir=$(cd "$build_dir" && pwd -P)
app="$(cd "$output_dir" && pwd -P)/DiskSlop.app"
bundle="$app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
sdk=$(xcrun --sdk macosx --show-sdk-path)
sparkle=$(./scripts/sparkle.sh)
compile_app() {
    xcrun --sdk macosx swiftc -O -swift-version 5 -sdk "$sdk" \
        -target "$1-apple-macos$MACOSX_DEPLOYMENT_TARGET" -module-cache-path "$build_dir/swift-cache" \
        -import-objc-header mac/DiskSlop.h mac/*.swift \
        "$2/libdiskslop.a" -framework AppKit -framework Foundation -F "$sparkle" -framework Sparkle \
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$3"
}
host_arch=$(uname -m)
build_rust() (
    separator=$(printf '\037')
    if [ -z "${CARGO_ENCODED_RUSTFLAGS+x}" ]; then
        CARGO_ENCODED_RUSTFLAGS=$(printf '%s' "${RUSTFLAGS:-}" | tr -s ' ' "$separator")
    fi
    for mapping in "$HOME=/build/home" "${CARGO_HOME:-$HOME/.cargo}=/cargo" "$PWD=/src" "$build_dir=/build/target"; do
        CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:+$CARGO_ENCODED_RUSTFLAGS$separator}--remap-path-prefix=$mapping"
    done
    export CARGO_ENCODED_RUSTFLAGS
    cargo build --locked --release "$@"
)
build_rust
compile_app "$host_arch" "$build_dir/release" "$bundle/MacOS/DiskSlop"
if [ "${1:-}" = --universal ]; then
    case "$host_arch" in
        arm64) other_arch=x86_64; other_target=x86_64-apple-darwin ;;
        x86_64) other_arch=arm64; other_target=aarch64-apple-darwin ;;
        *) echo "Unsupported macOS architecture: $host_arch" >&2; exit 1 ;;
    esac
    build_rust --lib --target "$other_target"
    other_dir="$build_dir/$other_target/release"
    thin=$(mktemp "$build_dir/.DiskSlop-$other_arch.XXXXXX")
    trap 'rm -f "$thin"' EXIT
    compile_app "$other_arch" "$other_dir" "$thin"
    xcrun lipo -create "$bundle/MacOS/DiskSlop" "$thin" -output "$bundle/MacOS/DiskSlop.universal"
    mv "$bundle/MacOS/DiskSlop.universal" "$bundle/MacOS/DiskSlop"
fi
xcrun strip -S "$bundle/MacOS/DiskSlop"
for binary in "$bundle/MacOS/DiskSlop" "$build_dir/release/diskslop"; do
    for prefix in "$HOME" "$PWD" "$build_dir" "${CARGO_HOME:-$HOME/.cargo}"; do
        if LC_ALL=C grep -aFq -- "$prefix/" "$binary"; then
            echo "A compiled executable contains an absolute build path." >&2
            exit 1
        fi
    done
done
cp mac/Info.plist "$bundle/Info.plist"
if [ -n "${DISKSLOP_SOURCE_REVISION:-}" ]; then
    plutil -insert DiskSlopSourceRevision -string "$DISKSLOP_SOURCE_REVISION" "$bundle/Info.plist"
fi
mkdir -p "$bundle/Resources/KindIcons"
cp mac/KindIcons/*.svg "$bundle/Resources/KindIcons/"
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$PWD/mac/AppIcon.icon" --compile "$bundle/Resources" --platform macosx \
        --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" --target-device mac \
        --app-icon AppIcon --standalone-icon-behavior all \
        --output-partial-info-plist "$build_dir/icon-info.plist"
else
    cp mac/AppIcon.icns "$bundle/Resources/"
fi
mkdir -p "$bundle/Frameworks"
framework="$bundle/Frameworks/Sparkle.framework"
rm -rf "$framework"
ditto "$sparkle/Sparkle.framework" "$framework"
fw_version="$framework/Versions/Current"
for component in Headers PrivateHeaders Modules XPCServices; do
    rm -rf "$fw_version/$component" "$framework/$component"
done
cp LICENSE THIRD-PARTY-NOTICES.txt "$bundle/Resources/"
rust_notice="$(rustc --print sysroot)/share/doc/rust/COPYRIGHT-library.html"
if [ -f "$rust_notice" ]; then cp "$rust_notice" "$bundle/Resources/Rust-Library-Notices.html"; fi
if [ "${DISKSLOP_RELEASE_SIGNING:-0}" = 1 ]; then
    set -- --force --sign "$identity" --options runtime --timestamp
else
    set -- --force --sign "$identity" --timestamp=none
fi
codesign "$@" "$fw_version/Autoupdate" "$fw_version/Updater.app"
codesign "$@" "$framework"
codesign "$@" "$app"
