import AppKit
import UserNotifications

// Shows a macOS notification whenever the "Now Playing" song changes (browsers, Apple Music, Spotify).

// Single instance: clicking a notification makes macOS launch the app again. The launchd-managed
// copy (XPC_SERVICE_NAME == our label) wins; any other copy only handles the click, then exits,
// so popups are never doubled.
// (A lock file is used because launchd-started processes are invisible to NSRunningApplication.)
let isLaunchdInstance = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.quan.song-notifier"
let lockPath = NSTemporaryDirectory() + "com.quan.song-notifier.lock"
let lockFD = open(lockPath, O_RDWR | O_CREAT, 0o600)
let gotLock = flock(lockFD, LOCK_EX | LOCK_NB) == 0
let isClickHandler = !gotLock && !isLaunchdInstance
if !gotLock && isLaunchdInstance {
    let holder = (try? String(contentsOfFile: lockPath, encoding: .utf8)).flatMap { Int32($0) } ?? 0
    if holder > 0 { kill(holder, SIGTERM) }
    flock(lockFD, LOCK_EX)  // wait for the other copy to go away
}
if !isClickHandler {
    ftruncate(lockFD, 0)
    _ = "\(getpid())".withCString { write(lockFD, $0, strlen($0)) }
}

var lastTrack = ""

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .list])
    }

    // Notification clicked: bring the player that was playing the song to the front.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        focusPlayer(bundleID: info["bundleID"] as? String, pid: info["pid"] as? Int32, title: info["title"] as? String)
        h()
        if isClickHandler { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) } }
    }
}

// Browsers: switch to the tab whose title contains the song (needs Automation permission, asked once).
let tabScripts = [
    "chromium": """
        tell application id "%@"
          repeat with w in windows
            set i to 0
            repeat with t in tabs of w
              set i to i + 1
              if title of t contains "%@" then
                set active tab index of w to i
                set index of w to 1
                return true
              end if
            end repeat
          end repeat
        end tell
        """,
    "safari": """
        tell application id "%@"
          repeat with w in windows
            repeat with t in tabs of w
              if name of t contains "%@" then
                set current tab of w to t
                set index of w to 1
                return true
              end if
            end repeat
          end repeat
        end tell
        """,
]
let browserKinds = [
    "com.microsoft.edgemac": "chromium", "com.google.Chrome": "chromium",
    "com.brave.Browser": "chromium", "com.vivaldi.Vivaldi": "chromium", "com.apple.Safari": "safari",
]

func focusPlayer(bundleID: String?, pid: Int32?, title: String?) {
    guard let bundleID else { return }
    if let kind = browserKinds[bundleID], let title, !title.isEmpty {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: String(format: tabScripts[kind]!, bundleID, escaped))?.executeAndReturnError(&err)
        if let err { print("tab focus failed:", err) }
    }
    let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    app?.activate()
}
let delegate = Delegate()
let un = UNUserNotificationCenter.current()
un.delegate = delegate
let app = NSApplication.shared  // needed for notification clicks to be delivered
app.setActivationPolicy(.accessory)

if isClickHandler {
    // launched by a notification click: handle it (delegate above), or give up quietly
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    app.run()
}
un.requestAuthorization(options: [.alert]) { granted, err in
    print("notification permission granted:", granted, err?.localizedDescription ?? "")
}

func notify(title: String, body: String, player: [String: Any]) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    c.userInfo = player
    un.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// Now Playing state is fed by `media-control stream` (brew install ungive/media-control/media-control),
// which reports whatever macOS considers "now playing": browsers, Apple Music, Spotify, ...
var state: [String: Any] = [:]

func handle(line: String) {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let payload = obj["payload"] as? [String: Any] else { return }
    if (obj["diff"] as? Bool) == true {
        for (k, v) in payload { if v is NSNull { state[k] = nil } else { state[k] = v } }
    } else {
        state = payload
    }
    scheduleNotify()
}

// Browsers publish the title first and artist/album a moment later (sometimes a second title tweak too).
// Wait for the metadata to settle, then notify once per track (keyed on title only).
var pending: DispatchWorkItem?

func scheduleNotify() {
    pending?.cancel()
    let work = DispatchWorkItem {
        guard (state["playing"] as? Bool) == true,
              let name = state["title"] as? String, !name.isEmpty, name != lastTrack else { return }
        lastTrack = name
        let artist = state["artist"] as? String ?? ""
        let album = state["album"] as? String ?? ""
        var player: [String: Any] = ["title": name]
        player["bundleID"] = state["bundleIdentifier"] as? String
        player["pid"] = state["processIdentifier"] as? Int32
        notify(title: name, body: [artist, album].filter { !$0.isEmpty }.joined(separator: " — "), player: player)
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/media-control")
proc.arguments = ["stream"]
let pipe = Pipe()
proc.standardOutput = pipe
var buffer = Data()
pipe.fileHandleForReading.readabilityHandler = { fh in
    let chunk = fh.availableData
    if chunk.isEmpty { exit(1) }  // helper died; launchd restarts us
    buffer.append(chunk)
    while let nl = buffer.firstIndex(of: 10) {
        let line = String(decoding: buffer[..<nl], as: UTF8.self)
        buffer.removeSubrange(...nl)
        DispatchQueue.main.async { handle(line: line) }
    }
}
try proc.run()

// don't leave the helper orphaned when we are stopped
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { proc.terminate(); exit(0) }
term.resume()

print("Listening for song changes via macOS Now Playing. Ctrl+C to quit.")
app.run()
