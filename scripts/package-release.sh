#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Shards.xcodeproj"
SCHEME="Shards"
CONFIGURATION="Release"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CREATE_DMG=0

timestamp="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="$ROOT_DIR/release/$timestamp"
ARCHIVE_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [options]

Options:
  --output-dir <path>     Output directory for the packaged build
  --archive-path <path>   Override the xcarchive output path
  --project <path>        Xcode project path (default: Shards.xcodeproj)
  --scheme <name>         Xcode scheme to archive (default: Shards)
  --configuration <name>  Build configuration (default: Release)
  --create-dmg            Also create a distributable DMG
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      shift
      OUTPUT_DIR="${1:-}"
      if [[ -z "$OUTPUT_DIR" ]]; then
        echo "Missing value for --output-dir" >&2
        exit 1
      fi
      ;;
    --archive-path)
      shift
      ARCHIVE_PATH="${1:-}"
      if [[ -z "$ARCHIVE_PATH" ]]; then
        echo "Missing value for --archive-path" >&2
        exit 1
      fi
      ;;
    --project)
      shift
      PROJECT_PATH="${1:-}"
      if [[ -z "$PROJECT_PATH" ]]; then
        echo "Missing value for --project" >&2
        exit 1
      fi
      ;;
    --scheme)
      shift
      SCHEME="${1:-}"
      if [[ -z "$SCHEME" ]]; then
        echo "Missing value for --scheme" >&2
        exit 1
      fi
      ;;
    --configuration)
      shift
      CONFIGURATION="${1:-}"
      if [[ -z "$CONFIGURATION" ]]; then
        echo "Missing value for --configuration" >&2
        exit 1
      fi
      ;;
    --create-dmg)
      CREATE_DMG=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$ARCHIVE_PATH" ]]; then
  ARCHIVE_PATH="$OUTPUT_DIR/${SCHEME}.xcarchive"
fi

xcodebuild_path="$DEVELOPER_DIR/usr/bin/xcodebuild"
if [[ ! -x "$xcodebuild_path" ]]; then
  echo "Xcode not found at $xcodebuild_path" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

build_settings="$(
  "$xcodebuild_path" -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null
)"

bundle_id="$(awk -F ' = ' '/PRODUCT_BUNDLE_IDENTIFIER/ { print $2; exit }' <<<"$build_settings")"
marketing_version="$(awk -F ' = ' '/MARKETING_VERSION/ { print $2; exit }' <<<"$build_settings")"
build_number="$(awk -F ' = ' '/CURRENT_PROJECT_VERSION/ { print $2; exit }' <<<"$build_settings")"
full_product_name="$(awk -F ' = ' '/FULL_PRODUCT_NAME/ { print $2; exit }' <<<"$build_settings")"
app_name="${full_product_name%.app}"

if [[ -z "$app_name" ]]; then
  app_name="$SCHEME"
fi

if [[ "$bundle_id" == com.yourdomain.* ]]; then
  echo "Warning: bundle identifier is still a placeholder ($bundle_id)." >&2
  echo "         Replace it before shipping a public build." >&2
fi

if [[ -z "$marketing_version" || -z "$build_number" ]]; then
  echo "Warning: MARKETING_VERSION or CURRENT_PROJECT_VERSION is missing." >&2
  echo "         Set both before publishing a release." >&2
fi

echo "Archiving $SCHEME..."
"$xcodebuild_path" \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

archived_app="$ARCHIVE_PATH/Products/Applications/${app_name}.app"
release_app="$OUTPUT_DIR/${app_name}.app"
release_zip="$OUTPUT_DIR/${app_name}.zip"
release_dmg="$OUTPUT_DIR/${app_name}.dmg"

rm -rf "$release_app" "$release_zip" "$release_dmg"
ditto "$archived_app" "$release_app"
ditto -c -k --sequesterRsrc --keepParent "$release_app" "$release_zip"

if [[ "$CREATE_DMG" -eq 1 ]]; then
  dmg_root="$OUTPUT_DIR/dmg-root"
  rm -rf "$dmg_root"
  mkdir -p "$dmg_root"
  ditto "$release_app" "$dmg_root/${app_name}.app"
  hdiutil create -volname "$app_name" -srcfolder "$dmg_root" -ov -format UDZO "$release_dmg" >/dev/null
  rm -rf "$dmg_root"
fi

echo
echo "Bundle ID: ${bundle_id:-<missing>}"
echo "Version: ${marketing_version:-<missing>} (${build_number:-<missing>})"
echo "Archive: $ARCHIVE_PATH"
echo "App: $release_app"
echo "Zip: $release_zip"
if [[ "$CREATE_DMG" -eq 1 ]]; then
  echo "DMG: $release_dmg"
fi

echo
echo "Next steps:"
echo "  1. Without an Apple Developer account, distribute this as an unsigned personal build."
echo "  2. For a warning-free public build, sign with Developer ID, notarize, and staple it."
echo "  3. For Sparkle, use scripts/prepare-sparkle-release.sh to sign the update archive."
