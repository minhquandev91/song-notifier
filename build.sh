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

# icon: use tools/icon-source.{jpg,png} if present (squircle crop + note badge),
# otherwise the code-drawn icon. Then build the .icns.
TMP=$(mktemp -d)
ICON_PNG=tools/icon1024.png
swiftc tools/make-icon.swift -o $TMP/make-icon
$TMP/make-icon tools/icon1024.png
for src in tools/icon-source.jpg tools/icon-source.png; do
  if [[ -f $src ]]; then
    swiftc tools/make-icon-from-image.swift -o $TMP/make-icon-from-image
    $TMP/make-icon-from-image $src $TMP/icon-from-image.png
    ICON_PNG=$TMP/icon-from-image.png
    break
  fi
done
ICONSET=$TMP/AppIcon.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s $ICON_PNG --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $ICON_PNG --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

codesign --force --deep -s - $APP

# login agent: point it at this checkout and (re)start it
sed "s#__APP_BINARY__#$PWD/$APP/Contents/MacOS/song-notifier#" $AGENT.plist > $PLIST
launchctl bootout gui/$(id -u) $PLIST 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PLIST
killall NotificationCenter 2>/dev/null || true
echo "Built and started $APP"
