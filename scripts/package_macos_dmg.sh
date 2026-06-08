#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-build/macos/Build/Products/Release/EasyTier Pro.app}"
output_path="${2:-dist/easytier-pro-macos.dmg}"
volume_name="${3:-EasyTier Pro}"

if [[ ! -d "$app_path" ]]; then
  echo "macOS app bundle was not found: $app_path" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"
staging_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

ditto "$app_path" "$staging_dir/$(basename "$app_path")"
ln -s /Applications "$staging_dir/Applications"

rm -f "$output_path"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$output_path"

echo "macOS DMG produced: $output_path"
