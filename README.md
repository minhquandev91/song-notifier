# Song Notifier

<img src="tools/icon1024.png" width="128" align="right" alt="icon">

A tiny macOS menu-less app that pops up a notification whenever the song changes —
in **any browser** (Edge, Chrome, Safari… e.g. YouTube, YouTube Music, Spotify Web),
**Apple Music**, or **Spotify**.

```
┌──────────────────────────────────────────┐
│ 🎧 Song Notifier                     now │
│ Với Anh Em Vẫn Là Cô Bé                  │
│ KAI Hâm Nhạc                             │
└──────────────────────────────────────────┘
```

## How it works

- Reads the system **Now Playing** info (the same data shown in Control Center) via
  [`media-control`](https://github.com/ungive/media-control). Apple restricts direct access to
  this on macOS 15.4+; `media-control` works around it.
- Waits ~1 s after a change so late-arriving artist/album metadata lands in the same popup,
  and notifies once per track title (pause/resume does not re-notify).
- Runs as a background agent (`LSUIElement`, no Dock icon), started at login by launchd.

## Install

```sh
brew tap ungive/media-control && brew install media-control
./build.sh
```

`build.sh` compiles the app, renders the icon, signs it ad-hoc, installs
`~/Library/LaunchAgents/com.quan.song-notifier.plist`, and starts it.
On first run, allow notifications from **Song Notifier** when macOS asks
(or in System Settings → Notifications).

## Manage

```sh
launchctl kickstart -k gui/$(id -u)/com.quan.song-notifier                       # restart
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.quan.song-notifier.plist  # stop
```

Uninstall: stop it, then delete the LaunchAgent plist and this folder.

## Files

| File | Purpose |
|---|---|
| `SongNotifier.swift` | The app: reads the `media-control stream` JSON, debounces, posts notifications |
| `Info.plist` | App bundle metadata (bundle id, background-only, icon) |
| `com.quan.song-notifier.plist` | LaunchAgent template (`build.sh` fills in the path) |
| `tools/make-icon.swift` | Draws the icon in code: a nervous pink-haired guitarist girl with headphones |
| `build.sh` | Build + install + (re)start |

## Troubleshooting

- **No popup:** check System Settings → Notifications → Song Notifier, and Focus mode.
- **Old icon showing:** `killall NotificationCenter Dock` (macOS caches icons).
- **Stopped working after a brew cleanup:** `media-control` must be at `/opt/homebrew/bin/media-control`.
