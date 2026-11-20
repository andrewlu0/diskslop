#!/bin/sh
set -eu
mode=${3:-create}
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || { [ "$mode" != create ] && [ "$mode" != verify ]; }; then
    echo "Usage: make-appcast.sh <release assets directory> <built app Info.plist> [create|verify]" >&2
    exit 2
fi
assets=$(cd "$1" && pwd -P)
info=$2
tools=$("$(dirname "$0")/sparkle.sh")/bin
account=$(plutil -extract CFBundleIdentifier raw -o - "$info")
version=$(plutil -extract CFBundleShortVersionString raw -o - "$info")
build=$(plutil -extract CFBundleVersion raw -o - "$info")
release="https://github.com/andrewlu0/diskslop/releases"
prefix="$release/download/v$version/"
feed="$assets/appcast.xml"
set -- --account "$account"
if [ -n "${DISKSLOP_UPDATE_KEY_FILE:-}" ]; then set -- --ed-key-file "$DISKSLOP_UPDATE_KEY_FILE"; fi
if [ "$mode" = create ]; then
    "$tools/generate_appcast" "$@" --maximum-deltas 0 --download-url-prefix "$prefix" --link "$release/tag/v$version" "$assets"
fi
"$tools/sign_update" "$@" --verify "$feed"
xmlvalue() { xmllint --xpath "string(/rss/channel/item[1]/$1)" "$feed"; }
if [ "$(xmlvalue 'enclosure/@url')" != "${prefix}DiskSlop.dmg" ] || \
   [ "$(xmlvalue '*[local-name()="version"]')" != "$build" ]; then
    echo "The signed feed must identify this build and its version-specific disk image." >&2
    exit 1
fi
signature=$(xmlvalue 'enclosure/@*[local-name()="edSignature"]')
"$tools/sign_update" "$@" --verify "$assets/DiskSlop.dmg" "$signature"
