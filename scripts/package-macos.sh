#!/bin/sh
set -eu
cd -P "$(dirname "$0")/.."

case "$#:${1:-}" in
    1:local) name=DiskSlop-local.dmg ;;
    1:release)
        : "${DISKSLOP_DEVELOPER_ID:?Set the Developer ID Application signing identity}"
        : "${DISKSLOP_NOTARY_PROFILE:?Set the notarytool keychain profile name}"
        unset DISKSLOP_UPDATE_KEY_FILE
        export DISKSLOP_SIGN_IDENTITY="$DISKSLOP_DEVELOPER_ID" DISKSLOP_RELEASE_SIGNING=1
        name=DiskSlop.dmg
        ;;
    *) echo "Usage: scripts/package-macos.sh local|release" >&2; exit 2 ;;
esac

dist="${DISKSLOP_DIST_DIR:-target/dist}"
mkdir -p "$dist"
dist=$(cd "$dist" && pwd -P)
stage=$(mktemp -d "$dist/.package.XXXXXX")
mountpoint="$stage/mounted"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach "$mountpoint" >/dev/null || return 1
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
payload="$stage/contents"
app="$payload/DiskSlop.app"
artifacts="$stage/artifacts"
image="$artifacts/$name"
mkdir "$payload" "$mountpoint" "$artifacts"
source_dir="$PWD"
if [ "$1" = release ]; then
    if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
        echo "Commit the intended release source so the DMG can be tied to that revision." >&2
        exit 1
    fi
    DISKSLOP_SOURCE_REVISION=$(git rev-parse HEAD)
    export DISKSLOP_SOURCE_REVISION
    source_dir="$stage/source"
    mkdir "$source_dir"
    git archive --output="$stage/source.tar" "$DISKSLOP_SOURCE_REVISION"
    tar -xf "$stage/source.tar" -C "$source_dir"
    build_cache="${CARGO_TARGET_DIR:-target}"
    mkdir -p "$build_cache"
    CARGO_TARGET_DIR=$(cd "$build_cache" && pwd -P)
    export CARGO_TARGET_DIR
    sparkle=$("$source_dir/scripts/sparkle.sh")
    info="$source_dir/mac/Info.plist"
    account=$(plutil -extract CFBundleIdentifier raw -o - "$info")
    expected_key=$(plutil -extract SUPublicEDKey raw -o - "$info")
    signing_key=$("$sparkle/bin/generate_keys" --account "$account" -p)
    if [ -z "$expected_key" ] || [ "$signing_key" != "$expected_key" ]; then
        echo "The Keychain update signing key must match the public key in this release." >&2
        exit 1
    fi
fi
DISKSLOP_OUTPUT_DIR="$payload" "$source_dir/build-app.sh" --universal
ln -s /Applications "$payload/Applications"

if [ "$1" = release ]; then
    codesign --verify --strict --all-architectures \
        --test-requirement '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
fi

hdiutil create -quiet -volname DiskSlop -fs HFS+ -format UDZO -srcfolder "$payload" "$image"
if [ "$1" = release ]; then
    codesign --force --timestamp --identifier local.diskslop.app.dmg --sign "$DISKSLOP_DEVELOPER_ID" "$image"
    xcrun notarytool submit "$image" --keychain-profile "$DISKSLOP_NOTARY_PROFILE" \
        --wait --output-format plist > "$stage/notary.plist"
    status=$(plutil -extract status raw -o - "$stage/notary.plist")
    if [ "$status" != Accepted ]; then
        id=$(plutil -extract id raw -o - "$stage/notary.plist")
        echo "Notarization ended with $status. See notarytool log for submission $id." >&2
        exit 1
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi

hdiutil verify -quiet "$image"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" "$image"
mounted=true
installed="$mountpoint/DiskSlop.app"
[ "$(readlink "$mountpoint/Applications")" = /Applications ]
for binary in "$installed/Contents/MacOS/DiskSlop" "$installed/Contents/Helpers/diskslop"; do
    architectures=$(xcrun lipo -archs "$binary")
    case "$architectures" in
        'arm64 x86_64'|'x86_64 arm64') printf 'Verified %s: %s\n' "$binary" "$architectures" ;;
        *) echo "Expected a universal binary, found $architectures." >&2; exit 1 ;;
    esac
done
"$installed/Contents/Helpers/diskslop" --json --summary "$installed/Contents/MacOS" | plutil -extract allocated_bytes raw -o - -
codesign --verify --deep --strict --all-architectures "$installed"
test -s "$installed/Contents/Resources/THIRD-PARTY-NOTICES.txt"
test -x "$installed/Contents/Frameworks/Sparkle.framework/Autoupdate"
if [ "$1" = release ]; then
    spctl --assess --type execute --verbose=2 "$installed"
fi
hdiutil detach "$mountpoint" -quiet
mounted=false
(cd "$artifacts" && shasum -a 256 "$name" > "$name.sha256")
if [ "$1" = release ]; then
    "$source_dir/scripts/make-appcast.sh" "$artifacts" "$app/Contents/Info.plist"
fi
mv -f "$artifacts"/* "$dist/"
printf '%s\n' "$dist/$name"
