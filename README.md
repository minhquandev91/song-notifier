# Song Notifier

<img src="tools/icon1024.png" width="128" align="right" alt="icon">

A tiny macOS menu bar app that pops up a notification whenever the song changes —
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
- Shows the song rolling through the menu bar (♫ item); click it for **Settings…** and **Quit**.
- Click a popup to jump to the player: the app comes to the front, and in Edge/Chrome/Brave/Vivaldi/Safari
  the tab playing the song is selected (macOS asks once to allow controlling the browser).
- Runs as a background app (`LSUIElement`, no Dock icon).

## Settings

Open from the menu bar item (or by opening Song Notifier again if the item is hidden):
**Launch at login** (a regular macOS login item, listed in System Settings → General → Login Items),
**show the song in the menu bar**, **roll long titles**, and **show popups**.

## Install

```sh
brew tap ungive/media-control && brew install media-control
./build.sh
```

`build.sh` compiles the app into `~/Applications/SongNotifier.app`, renders the icon, signs it ad-hoc, and starts it
(it also removes the pre-0.2.0 launchd agent). On first run the Settings window opens: tick **Launch at login**
if you want it at startup, and allow notifications from **Song Notifier** when macOS asks
(or in System Settings → Notifications).

## Custom icon picture

Drop any square-ish picture at `tools/icon-source.jpg` (or `.png`) and run `./build.sh` —
it is cropped to a full-bleed square with a ♫ badge (macOS applies the rounded mask). Without it, the code-drawn icon is used.
The picture is git-ignored, so third-party artwork stays out of the repo.

## Manage

Quit from the menu bar item. Uninstall: untick **Launch at login**, quit, then delete
`~/Applications/SongNotifier.app` and this folder.

## Files

| File | Purpose |
|---|---|
| `SongNotifier.swift` | The app: reads the `media-control stream` JSON, posts notifications, menu bar item, settings window |
| `Info.plist` | App bundle metadata (bundle id, background-only, icon) |
| `tools/make-icon.swift` | Draws the default icon in code: a nervous pink-haired guitarist girl with headphones |
| `tools/make-icon-from-image.swift` | Turns any picture into an icon (full-bleed square crop + music-note badge) |
| `build.sh` | Build + install + (re)start (and remove the old launchd agent) |

## Troubleshooting

- **No popup:** check System Settings → Notifications → Song Notifier, and Focus mode.
- **Old icon showing:** `killall NotificationCenter Dock` (macOS caches icons).
- **Blank icon in the popup:** macOS caches the notification icon per bundle id, including a blank
  one from a build that had no icon yet. Bump `CFBundleIdentifier` in `Info.plist` and rebuild.
- **Stopped working after a brew cleanup:** `media-control` must be at `/opt/homebrew/bin/media-control`.
