#!/bin/zsh
# Builds SongNotifier.app (binary + icon), signs it ad-hoc, and (re)starts the login agent.
set -euo pipefail
cd "${0:A:h}"

APP=SongNotifier.app
AGENT=com.quan.song-notifier
PLIST=~/Library/LaunchAgents/$AGENT.plist

command -v media-control >/dev/null || {
  echo "media-control missing: brew tap ungive/media-control && brew install media-control" >&2; exit 1; }

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/Info.plist
swiftc -O SongNotifier.swift -o $APP/Contents/MacOS/song-notifier

# icon: render 1024px PNG from code, then build the .icns
swiftc tools/make-icon.swift -o /tmp/song-notifier-make-icon
/tmp/song-notifier-make-icon tools/icon1024.png
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s tools/icon1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) tools/icon1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

codesign --force --deep -s - $APP

# login agent: point it at this checkout and (re)start it
sed "s#__APP_BINARY__#$PWD/$APP/Contents/MacOS/song-notifier#" $AGENT.plist > $PLIST
launchctl bootout gui/$(id -u) $PLIST 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PLIST
killall NotificationCenter 2>/dev/null || true
echo "Built and started $APP"
