# Packaging for macOS

## Make a disk image for local testing

Install both Rust targets once, then build the image.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
./scripts/package-macos.sh local
open target/dist/DiskSlop-local.dmg
```

The image contains the universal app and an Applications shortcut. Local builds use the same signing identity as `build-app.sh`. The packaging command mounts the finished image read-only, checks both processor architectures and the app signature, and writes a SHA-256 checksum next to it.

## Publish a Mac download

Set `CFBundleShortVersionString` to the release version and increase the integer `CFBundleVersion` for every update. Commit the candidate and run the packaging command from that clean checkout. It builds an archive of the exact commit and records the commit ID in the signed app. Set `DISKSLOP_DEVELOPER_ID` to the Developer ID Application signing identity and `DISKSLOP_NOTARY_PROFILE` to the name of a saved notarytool Keychain profile.

```sh
./scripts/package-macos.sh release
```

The command signs Sparkle’s helpers, the framework, the app and the disk image. It submits the image to Apple, staples the accepted ticket, and checks the mounted result with Gatekeeper. It then writes `DiskSlop.dmg`, `DiskSlop.dmg.sha256` and a signed `appcast.xml` into `target/dist/`. [Apple’s macOS packaging guide](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

Test that same DMG on the oldest macOS version you intend to support. Open it in Finder, drag DiskSlop into Applications, choose a folder through the Open panel, grant folder access if prompted, then quit and reopen it. Confirm that the folder scans again and that **Check for Updates…** is available.

Push the tested commit and its `v<version>` tag to the project repository. Publish the DMG you tested with the command below. It checks the tag against the embedded commit, verifies the feed and disk image signatures, and checks that the new build number advances. GitHub’s latest stable release serves the signed feed. Each feed entry points to the DMG at its own version tag. Drafts and GitHub prereleases stay outside this update channel.

```sh
./scripts/publish-release.sh
```

After the first public release, run `./scripts/link-download.sh` and commit the README change. It verifies all three assets against GitHub before linking the download button. [GitHub release download links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

For each public download, update the version, asset URL and SHA-256 in the [DiskSlop Homebrew cask](https://github.com/andrewlu0/homebrew-tap/blob/main/Casks/diskslop.rb). Remove the preview caveat for the first notarized release. Verify the installed app with `brew install --cask andrewlu0/tap/diskslop` on a fresh installation or `brew upgrade --cask andrewlu0/tap/diskslop` on an existing one.

## Update signing

The DiskSlop Ed25519 private key is stored in the maintainer’s login Keychain under the account `local.diskslop.app`. Only its public half, `SUPublicEDKey`, is in the source. Keep a secure backup of the original signing key so a new Mac can publish updates to existing installations. The pinned Sparkle tools support Keychain export and import with `generate_keys`. [Sparkle signing and key rotation](https://sparkle-project.org/documentation/)

Sparkle asks about background checks on the second launch. Users can opt into automatic downloads and installation, change their choices in Settings, or run a manual check. Automatic installation can wait for normal app termination. A relaunch waits for any active move to Trash to finish.

After downloading the image and its checksum into the same folder, a reader can verify the download with `shasum -a 256 -c DiskSlop.dmg.sha256`.
