#!/bin/sh
set -eu
cd -P "$(dirname "$0")/.."
repo=andrewlu0/diskslop
dist=$(cd "${DISKSLOP_DIST_DIR:-target/dist}" && pwd -P)
image="$dist/DiskSlop.dmg"
(cd "$dist" && shasum -a 256 -c DiskSlop.dmg.sha256)
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature "$image"

stage=$(mktemp -d)
mountpoint="$stage/mounted"
mkdir "$mountpoint"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then hdiutil detach "$mountpoint" -quiet || return 1; fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" "$image"
mounted=true
info="$mountpoint/DiskSlop.app/Contents/Info.plist"
tag="v$(plutil -extract CFBundleShortVersionString raw -o - "$info")"
build=$(plutil -extract CFBundleVersion raw -o - "$info")
revision=$(plutil -extract DiskSlopSourceRevision raw -o - "$info")
remote_revision=$(gh api "repos/$repo/commits/$tag" --jq .sha)
if [ "$revision" != "$remote_revision" ]; then
    echo "The disk image was built from $revision. The GitHub tag $tag points to $remote_revision." >&2
    exit 1
fi
unset DISKSLOP_UPDATE_KEY_FILE
./scripts/make-appcast.sh "$dist" "$info" verify
feed=$(plutil -extract SUFeedURL raw -o - "$info")
code=$(curl --silent --show-error --location --proto '=https' -o "$stage/previous.xml" -w '%{http_code}' "$feed")
case "$code" in
    200)
        sparkle=$(./scripts/sparkle.sh)
        account=$(plutil -extract CFBundleIdentifier raw -o - "$info")
        "$sparkle/bin/sign_update" --account "$account" --verify "$stage/previous.xml"
        previous=$(xmllint --xpath 'string(/rss/channel/item[1]/*[local-name()="version"])' "$stage/previous.xml")
        if ! [ "$build" -gt "$previous" ]; then
            echo "Increase CFBundleVersion above the published build $previous." >&2
            exit 1
        fi ;;
    404) ;;
    *) echo "Could not check the published update feed (HTTP $code)." >&2; exit 1 ;;
esac
hdiutil detach "$mountpoint" -quiet
mounted=false
gh release create "$tag" "$image" "$image.sha256" "$dist/appcast.xml" \
    --repo "$repo" --verify-tag --generate-notes --latest
