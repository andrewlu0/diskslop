#!/bin/sh
set -eu
cd -P "$(dirname "$0")/.."

repo=andrewlu0/diskslop
url="https://github.com/$repo/releases/latest/download/DiskSlop.dmg"
dist="${DISKSLOP_DIST_DIR:-target/dist}"
(cd "$dist" && shasum -a 256 -c DiskSlop.dmg.sha256)
assets=$(gh api "repos/$repo/releases/latest" --jq '.assets[] | select(.state == "uploaded") | "\(.name) \(.digest)"')
for name in DiskSlop.dmg DiskSlop.dmg.sha256 appcast.xml; do
    digest=$(shasum -a 256 "$dist/$name")
    if ! printf '%s\n' "$assets" | grep -Fxq "$name sha256:${digest%% *}"; then
        echo "The latest public release must contain the matching $name before linking the download." >&2
        exit 1
    fi
done

button='><img src="docs/download-macos.svg"'
grep -Fq "$button" README.md
sed -i '' -E \
    -e "s|href=\"[^\"]*\"(><img src=\"docs/download-macos\\.svg\")|href=\"$url\"\\1|" \
    -e 's/alt="Download the DiskSlop preview for macOS"/alt="Download DiskSlop for macOS"/' \
    -e '/^<p align="center"><strong>Public preview<\/strong>/d' \
    -e 's/ While the first image is in preparation, you can build the app locally\.//' README.md
grep -Fq "href=\"$url\"$button" README.md
printf 'README download button: %s\n' "$url"
