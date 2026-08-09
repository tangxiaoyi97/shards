# Shards Release Guide

Shards uses the bundle identifier `com.tangxiaoyi.Shards` and semantic release versions. The repository can produce locally signed archives without additional configuration.

## Before public distribution

1. Configure an Apple Developer team and a `Developer ID Application` certificate in Xcode.
2. Confirm `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`.
3. Run the complete test and archive checks below.
4. Decide the distribution channel:
   - Direct download: archive, notarize, staple, ship `.dmg` or `.zip`
   - Mac App Store: archive with App Store signing and upload through Organizer/Transporter

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

The generated app is suitable for local testing. It is not ready for public download until it is signed with Developer ID and notarized.

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
3. Run `zsh scripts/package-release.sh --create-dmg`
4. Notarize and staple the shipping artifact
5. Validate the final artifact on a clean machine or fresh macOS user account
