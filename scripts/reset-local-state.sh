#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Shards.xcodeproj"
SCHEME="Shards"
APP_NAME="Shards"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

bundle_id=""
include_settings=0
include_derived_data=0

usage() {
  cat <<'EOF'
Usage: scripts/reset-local-state.sh [options]

Options:
  --include-settings      Remove UserDefaults/preferences
  --include-derived-data  Remove Xcode DerivedData for this app
  --all                   Remove app data, settings, and DerivedData
  --bundle-id <id>        Override the detected bundle identifier
  -h, --help              Show this help message
EOF
}

detect_bundle_id() {
  if [[ -n "$bundle_id" ]]; then
    echo "$bundle_id"
    return
  fi

  local xcodebuild_path="$DEVELOPER_DIR/usr/bin/xcodebuild"
  if [[ -x "$xcodebuild_path" && -d "$PROJECT_PATH" ]]; then
    local detected
    detected="$(
      "$xcodebuild_path" -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
      | awk -F ' = ' '/PRODUCT_BUNDLE_IDENTIFIER/ { print $2; exit }'
    )"
    if [[ -n "$detected" ]]; then
      echo "$detected"
      return
    fi
  fi

  echo "com.tangxiaoyi.Shards"
}

remove_if_present() {
  local target_path="$1"
  if [[ -e "$target_path" ]]; then
    rm -rf "$target_path"
    echo "Removed: $target_path"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-settings)
      include_settings=1
      ;;
    --include-derived-data)
      include_derived_data=1
      ;;
    --all)
      include_settings=1
      include_derived_data=1
      ;;
    --bundle-id)
      shift
      bundle_id="${1:-}"
      if [[ -z "$bundle_id" ]]; then
        echo "Missing value for --bundle-id" >&2
        exit 1
      fi
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

bundle_id="$(detect_bundle_id)"

app_support_dir="$HOME/Library/Application Support/$APP_NAME"
saved_state_dir="$HOME/Library/Saved Application State/${bundle_id}.savedState"
preferences_plist="$HOME/Library/Preferences/${bundle_id}.plist"
caches_dir="$HOME/Library/Caches/${bundle_id}"
http_storages_dir="$HOME/Library/HTTPStorages/${bundle_id}"
webkit_dir="$HOME/Library/WebKit/${bundle_id}"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 1
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
fi

echo "Resetting local state for $APP_NAME ($bundle_id)..."
remove_if_present "$app_support_dir"
remove_if_present "$saved_state_dir"
remove_if_present "$caches_dir"
remove_if_present "$http_storages_dir"
remove_if_present "$webkit_dir"

if [[ "$include_settings" -eq 1 ]]; then
  defaults delete "$bundle_id" >/dev/null 2>&1 || rm -f "$preferences_plist"
  echo "Removed settings for $bundle_id"
else
  echo "Preserved user settings."
fi

if [[ "$include_derived_data" -eq 1 ]]; then
  derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
  if [[ -d "$derived_data_root" ]]; then
    while IFS= read -r derived_path; do
      remove_if_present "$derived_path"
    done < <(find "$derived_data_root" -maxdepth 1 -type d -name "${APP_NAME}-*" -print)
  fi
fi

echo "Local reset complete."
