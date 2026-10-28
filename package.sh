#!/bin/zsh
# Builds a release app (code-drawn icon, not installed) and zips it to dist/SongNotifier-<version>.zip.
set -euo pipefail
cd "${0:A:h}"

APP=$PWD/dist/SongNotifier.app
rm -rf dist; mkdir -p dist
RELEASE=1 APP=$APP ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $APP/Contents/Info.plist)
ZIP=dist/SongNotifier-$VERSION.zip
ditto -c -k --norsrc --noextattr --keepParent $APP $ZIP
rm -rf $APP
echo "Packaged $ZIP ($(du -h $ZIP | cut -f1))"
echo "sha256 $(shasum -a 256 $ZIP | cut -d' ' -f1)"
