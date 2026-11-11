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
ditto -c -k --keepParent "$app" "$work/$archive"
shasum -a 256 < "$work/$archive" | awk '{print $1}' > "$work/$archive.sha256"
cp -- "$work/$archive" "$work/$archive.sha256" "$output/"
printf 'Release ZIP and SHA-256 written to %s\n' "$output"
