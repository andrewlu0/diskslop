#!/bin/sh
set -eu
cd -P "$(dirname "$0")/.."

version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
name="Sparkle-$version"
cache="${CARGO_TARGET_DIR:-target}/dependencies"
mkdir -p "$cache"
cache=$(cd "$cache" && pwd -P)
if [ ! -d "$cache/$name/Sparkle.framework" ]; then
    stage=$(mktemp -d "$cache/.sparkle.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    trap 'exit 1' HUP INT TERM
    archive="$name.tar.xz"
    curl --fail --silent --show-error --location --retry 2 --proto '=https' \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/$archive" -o "$stage/$archive"
    (cd "$stage" && printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -) >&2
    mkdir "$stage/$name"
    tar -xf "$stage/$archive" -C "$stage/$name" ./Sparkle.framework ./LICENSE \
        ./bin/generate_keys ./bin/generate_appcast ./bin/sign_update
    mv -n "$stage/$name" "$cache/" || test -d "$cache/$name/Sparkle.framework"
fi
printf '%s\n' "$cache/$name"
