#!/bin/zsh
# Builds SongNotifier.app (binary + icon), signs it ad-hoc, and (re)starts the login agent.
set -euo pipefail
cd "${0:A:h}"

# Installed in ~/Applications: macOS leaves the notification icon blank for apps in arbitrary folders.
APP=~/Applications/SongNotifier.app
AGENT=com.quan.song-notifier
PLIST=~/Library/LaunchAgents/$AGENT.plist

command -v media-control >/dev/null || {
  echo "media-control missing: brew tap ungive/media-control && brew install media-control" >&2; exit 1; }

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/Info.plist
swiftc -O SongNotifier.swift -o $APP/Contents/MacOS/song-notifier

# icon: use tools/icon-source.{jpg,png} if present (full-bleed crop + note badge),
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
# re-register the rebuilt bundle, otherwise the notification popup can show a blank icon
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $APP

# login agent: point it at the installed app and (re)start it
sed "s#__APP_BINARY__#$APP/Contents/MacOS/song-notifier#" $AGENT.plist > $PLIST
launchctl bootout gui/$(id -u) $PLIST 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PLIST
killall usernoted NotificationCenter 2>/dev/null || true
echo "Built and started $APP"
