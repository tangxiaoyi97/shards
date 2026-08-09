#!/bin/zsh

set -euo pipefail

SHARDS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARDS_OUTPUT_DIR="${1:-$SHARDS_ROOT/release/sparkle}"
SHARDS_PACKAGES_DIR="$SHARDS_ROOT/.build/SourcePackages"
SHARDS_PROJECT="$SHARDS_ROOT/Shards.xcodeproj"
SHARDS_ACCOUNT="com.tangxiaoyi.Shards"
SHARDS_REPOSITORY_URL="https://github.com/tangxiaoyi97/shards"
SHARDS_XCODEBUILD="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/usr/bin/xcodebuild"

mkdir -p "$SHARDS_OUTPUT_DIR" "$SHARDS_PACKAGES_DIR"

"$SHARDS_XCODEBUILD" \
  -resolvePackageDependencies \
  -project "$SHARDS_PROJECT" \
  -scheme Shards \
  -clonedSourcePackagesDirPath "$SHARDS_PACKAGES_DIR"

SHARDS_APPCAST_TOOL="$SHARDS_PACKAGES_DIR/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$SHARDS_APPCAST_TOOL" ]]; then
  echo "Sparkle's generate_appcast tool was not found at $SHARDS_APPCAST_TOOL" >&2
  exit 1
fi

zsh "$SHARDS_ROOT/scripts/package-release.sh" --output-dir "$SHARDS_OUTPUT_DIR"

SHARDS_APP="$SHARDS_OUTPUT_DIR/Shards.app"
SHARDS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SHARDS_APP/Contents/Info.plist")"
SHARDS_ZIP="$SHARDS_OUTPUT_DIR/Shards-v${SHARDS_VERSION}-macOS.zip"

mv "$SHARDS_OUTPUT_DIR/Shards.zip" "$SHARDS_ZIP"

"$SHARDS_APPCAST_TOOL" \
  --account "$SHARDS_ACCOUNT" \
  --download-url-prefix "$SHARDS_REPOSITORY_URL/releases/download/v${SHARDS_VERSION}/" \
  --link "$SHARDS_REPOSITORY_URL/releases" \
  --maximum-versions 1 \
  -o "$SHARDS_OUTPUT_DIR/appcast.xml" \
  "$SHARDS_OUTPUT_DIR"

echo
echo "Sparkle release prepared for v$SHARDS_VERSION:"
echo "  Archive: $SHARDS_ZIP"
echo "  Feed:    $SHARDS_OUTPUT_DIR/appcast.xml"
echo
echo "Attach both files to the GitHub release tagged v$SHARDS_VERSION."
