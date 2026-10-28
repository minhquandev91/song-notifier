import AppKit
import UserNotifications

// Shows a macOS notification whenever the "Now Playing" song changes (browsers, Apple Music, Spotify).

// Single instance: clicking a notification makes macOS launch the app again. The launchd-managed
// copy (XPC_SERVICE_NAME == our label) wins; any other copy exits so popups are never doubled.
// (A lock file is used because launchd-started processes are invisible to NSRunningApplication.)
let isLaunchdInstance = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.quan.song-notifier"
let lockPath = NSTemporaryDirectory() + "com.quan.song-notifier.lock"
let lockFD = open(lockPath, O_RDWR | O_CREAT, 0o600)
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    guard isLaunchdInstance else { exit(0) }
    let holder = (try? String(contentsOfFile: lockPath, encoding: .utf8)).flatMap { Int32($0) } ?? 0
    if holder > 0 { kill(holder, SIGTERM) }
    flock(lockFD, LOCK_EX)  // wait for the other copy to go away
}
ftruncate(lockFD, 0)
_ = "\(getpid())".withCString { write(lockFD, $0, strlen($0)) }

var lastTrack = ""

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .list])
    }
}
let delegate = Delegate()
let un = UNUserNotificationCenter.current()
un.delegate = delegate
un.requestAuthorization(options: [.alert]) { granted, err in
    print("notification permission granted:", granted, err?.localizedDescription ?? "")
}

func notify(title: String, body: String) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
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
        notify(title: name, body: [artist, album].filter { !$0.isEmpty }.joined(separator: " — "))
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
RunLoop.main.run()
