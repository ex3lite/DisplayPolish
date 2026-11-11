#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
output="${1:-$root/build/release}"
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/displaypolish-build.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT

xcodebuild -project "$root/DisplayPolish.xcodeproj" -scheme DisplayPolish \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build

app="$work/DerivedData/Build/Products/Release/DisplayPolish.app"
codesign --verify --deep --strict "$app"
archive=DisplayPolish-macOS-arm64.zip
image=DisplayPolish-macOS-arm64.dmg
ditto -c -k --keepParent "$app" "$work/$archive"

mkdir "$work/disk-image"
ditto "$app" "$work/disk-image/DisplayPolish.app"
ln -s /Applications "$work/disk-image/Applications"
hdiutil create -srcfolder "$work/disk-image" -volname DisplayPolish -fs HFS+ \
  -format UDZO "$work/$image"
hdiutil verify "$work/$image"

for file in "$archive" "$image"; do
  shasum -a 256 < "$work/$file" | awk '{print $1}' > "$work/$file.sha256"
  cp -- "$work/$file" "$work/$file.sha256" "$output/"
done
printf 'Release DMG, ZIP and SHA-256 files written to %s\n' "$output"
