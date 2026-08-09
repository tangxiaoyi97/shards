# Shards Release Guide

Shards uses bundle identifier `com.tangxiaoyi.Shards`, semantic versions, and Sparkle 2 for manually initiated updates.

## Two different signatures

- Sparkle Ed25519 signing proves an update archive came from this project and was not replaced. Its private key is stored in the local Login Keychain under account `com.tangxiaoyi.Shards`; only the public key is committed.
- Apple Developer ID signing and notarization tell Gatekeeper who published the app. A paid Apple Developer account is not required for personal builds, but other users will see a security warning without it.

## Before warning-free public distribution

1. Configure an Apple Developer team and a `Developer ID Application` certificate in Xcode.
2. Confirm `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`.
3. Run the complete test and archive checks below.
4. Archive, notarize, staple, and ship the final `.dmg` or `.zip`.

## Full local reset

Use this when you want to wipe app data, preferences, caches, and Xcode build cache:

```bash
zsh scripts/reset-local-state.sh --all
```

`--all` removes:

- `~/Library/Application Support/Shards`
- `~/Library/Saved Application State/<bundle-id>.savedState`
- `~/Library/Preferences/<bundle-id>.plist`
- `~/Library/Caches/<bundle-id>`
- `~/Library/HTTPStorages/<bundle-id>`
- `~/Library/WebKit/<bundle-id>`
- matching `~/Library/Developer/Xcode/DerivedData/Shards-*`

## Create a release package

For a local release archive plus a zipped app:

```bash
zsh scripts/package-release.sh
```

To also create a DMG:

```bash
zsh scripts/package-release.sh --create-dmg
```

The script writes output under `release/<timestamp>/`:

- `.xcarchive`
- `.app`
- `.zip`
- optional `.dmg`

The generated app is suitable for local testing. Without Developer ID and notarization, recipients may need to approve it in Privacy & Security.

## Prepare a Sparkle update

The GitHub repository (or at least a separate release-feed repository) must be public so the app can fetch the feed and archive without a GitHub token.

```bash
zsh scripts/prepare-sparkle-release.sh
```

The script builds `Shards-v<version>-macOS.zip`, signs it with the Sparkle key, and generates `appcast.xml`. Create the matching GitHub tag and attach both files to that release. The app reads the stable feed URL:

```text
https://github.com/tangxiaoyi97/shards/releases/latest/download/appcast.xml
```

Version 1.1 is the first Sparkle-enabled build, so it must be installed manually once. Updates published after it can be installed from Settings.

Never export or commit the private Sparkle key. If it is lost, installed builds cannot trust updates signed by a replacement key.

## Notarize for direct distribution

Example flow after `zsh scripts/package-release.sh --create-dmg`:

```bash
xcrun notarytool submit release/<timestamp>/Shards.dmg \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

xcrun stapler staple release/<timestamp>/Shards.dmg
spctl -a -t open --context context:primary-signature -v release/<timestamp>/Shards.dmg
```

If you distribute the `.zip` instead of the `.dmg`, notarize and staple the `.app` before re-zipping it for delivery.

## Recommended release checklist

1. Run `xcodebuild -project Shards.xcodeproj -scheme Shards -destination 'platform=macOS,arch=arm64' SWIFT_STRICT_CONCURRENCY=complete test`
2. Run `xcodebuild -project Shards.xcodeproj -scheme Shards -configuration Release -destination 'platform=macOS,arch=arm64' SWIFT_STRICT_CONCURRENCY=complete clean build`
3. Run `zsh scripts/prepare-sparkle-release.sh`
4. If available, sign with Developer ID, notarize, and staple the shipping artifact
5. Attach the versioned zip and `appcast.xml` to the matching GitHub release
6. Validate the final artifact on a clean machine or fresh macOS user account
