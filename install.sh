#!/bin/bash
set -euo pipefail

release_url=https://github.com/ex3lite/DisplayPolish/releases/latest/download
asset=DisplayPolish-macOS-arm64.zip
install_dir="$HOME/Applications"
archive=
launch=true

fail() {
  printf 'DisplayPolish: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'Provide a directory after --install-dir.'
      install_dir=$2
      shift 2
      ;;
    --archive)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'Provide a ZIP after --archive.'
      archive=$2
      shift 2
      ;;
    --no-launch) launch=false; shift ;;
    -h|--help)
      printf '%s\n' 'Usage: install.sh [--install-dir DIR] [--archive ZIP] [--no-launch]' \
        'An offline ZIP must have a matching ZIP.sha256 file beside it.'
      exit 0
      ;;
    *) fail "Unknown option $1." ;;
  esac
done

[ "$(uname -s)" = Darwin ] || fail 'This installer requires macOS.'
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ] || fail 'This build requires an Apple silicon Mac.'
IFS=. read -r major minor _ <<< "$(sw_vers -productVersion)"
if (( major < 26 || (major == 26 && minor < 3) )); then
  fail 'macOS 26.3 or later is required.'
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/displaypolish.XXXXXXXX")
staging=
destination=
lock=
cleanup() {
  if [ -n "$staging" ]; then
    if [ -e "$staging/previous.app" ] && [ ! -e "$destination" ]; then
      mv "$staging/previous.app" "$destination" || {
        printf 'Previous app is in %s\n' "$staging/previous.app" >&2
        [ -z "$lock" ] || rm -f -- "$lock"
        rm -rf -- "$work"
        return
      }
    fi
    rm -rf -- "$staging"
  fi
  [ -z "$lock" ] || rm -f -- "$lock"
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download() {
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$2" "$1"
}

if [ -z "$archive" ]; then
  archive="$work/$asset"
  download "$release_url/$asset" "$archive"
  download "$release_url/$asset.sha256" "$archive.sha256"
fi

[ -f "$archive" ] && [ -f "$archive.sha256" ] || fail 'The ZIP or its SHA-256 file is missing.'
expected=$(awk 'NR==1 {print $1} NR>1 {exit 1}' "$archive.sha256") || fail 'Invalid SHA-256 file.'
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Invalid SHA-256 checksum.'
actual=$(shasum -a 256 < "$archive")
[ "${actual%% *}" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ] || fail 'ZIP checksum mismatch.'

ditto -x -k "$archive" "$work/unpacked"
app="$work/unpacked/DisplayPolish.app"
bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}
[ "$(bundle_id "$app" || true)" = org.displaypolish.DisplayPolish ] || fail 'Invalid DisplayPolish bundle.'
codesign --verify --deep --strict "$app" || fail 'App signature verification failed.'

mkdir -p -- "$install_dir"
install_dir=$(cd -- "$install_dir" && pwd -P)
destination="$install_dir/DisplayPolish.app"
if /usr/bin/shlock -f "$install_dir/.displaypolish-install.lock" -p "$$"; then
  lock="$install_dir/.displaypolish-install.lock"
else
  fail 'Another DisplayPolish install is running.'
fi
[ ! -L "$destination" ] || fail 'The existing app is a symbolic link.'
if [ -e "$destination" ]; then
  [ "$(bundle_id "$destination" || true)" = org.displaypolish.DisplayPolish ] || fail 'The destination contains a different app.'
  if ps -axo comm= | awk -v executable="$destination/Contents/MacOS/DisplayPolish" \
       '$0 == executable {running=1} END {exit !running}'; then
    fail 'Quit the installed DisplayPolish from its menu before updating.'
  fi
fi

staging=$(mktemp -d "$install_dir/.displaypolish.XXXXXXXX")
ditto "$app" "$staging/DisplayPolish.app"
codesign --verify --deep --strict "$staging/DisplayPolish.app"
if [ -e "$destination" ]; then
  mv "$destination" "$staging/previous.app"
fi
mv "$staging/DisplayPolish.app" "$destination"
printf 'Installed %s\n' "$destination"
if $launch; then
  open "$destination"
fi
