import AppKit
import ServiceManagement
import UserNotifications

// Shows a macOS notification whenever the "Now Playing" song changes (browsers, Apple Music, Spotify),
// optionally with the song rolling through the menu bar. Clicking a popup focuses the player.

// A second copy (e.g. started by hand) would double every popup; the running one wins.
// The QA entry points (--snapshot, --history-test) must run alongside the app, so they opt out.
let snapshotMode = CommandLine.arguments.contains("--snapshot")
let historyTestMode = CommandLine.arguments.contains("--history-test")
let focusTestMode = CommandLine.arguments.contains("--focus-test")
// The QA entry points have to run alongside the app, so they opt out of the single-instance guard.
if !snapshotMode, !historyTestMode, !focusTestMode, let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

// MARK: - Settings (UserDefaults; every flag defaults to on)

enum Flag: String {
    case showPopups, showInMenuBar, scrollTitle, recentList, steerListening
    var isOn: Bool { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
    func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: rawValue) }
}

// MARK: - Focusing the player

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

// The link of a song is not in media-control's data, but while the song plays it is the URL of the browser
// tab playing it — so it is read from the tab once per track and kept with the history row.
// Last.fm credentials are stored in UserDefaults
let tabURLScripts = [
    "chromium": """
        tell application id "%@"
          repeat with w in windows
            repeat with t in tabs of w
              if title of t contains "%@" then return URL of t
            end repeat
          end repeat
        end tell
        """,
    "safari": """
        tell application id "%@"
          repeat with w in windows
            repeat with t in tabs of w
              if name of t contains "%@" then return URL of t
            end repeat
          end repeat
        end tell
        """,
]

// Inside the AppleScript string literals above, backslashes and quotes have to be escaped.
func scriptEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// Link of the browser tab playing `title`, or nil when no tab matches (or the player is not a browser).
func playingURL(bundleID: String?, title: String) -> String? {
    guard let bundleID, let kind = browserKinds[bundleID], !title.isEmpty else { return nil }
    var err: NSDictionary?
    let url = NSAppleScript(source: String(format: tabURLScripts[kind]!, bundleID, scriptEscaped(title)))?
        .executeAndReturnError(&err).stringValue
    if let err { print("tab link lookup failed:", err) }
    return (url?.hasPrefix("http") ?? false) ? url : nil
}

// Brings the player to the front, and for browsers also selects the tab playing that song.
// Returns true when a browser tab was actually selected (used by --focus-test; the other callers ignore it).
@discardableResult
func focusPlayer(bundleID: String?, pid: Int32?, title: String?) -> Bool {
    guard let bundleID else { return false }
    var selectedTab = false
    if let kind = browserKinds[bundleID], let title, !title.isEmpty {
        var err: NSDictionary?
        let result = NSAppleScript(source: String(format: tabScripts[kind]!, bundleID, scriptEscaped(title)))?
            .executeAndReturnError(&err)
        selectedTab = result?.booleanValue ?? false
        if let err { print("tab focus failed:", err) }
    }
    let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    app?.activate()
    // For non-browser players (e.g. Spotify), activating the app is the correct behavior.
    // Return true so we don't fall through to openInPlayer (which would open a new tab).
    return selectedTab || browserKinds[bundleID] == nil
}

// MARK: - Artwork

// Rounded square showing the player's artwork (cropped to fill), or a music-note placeholder.
final class ArtworkView: NSView {
    let placeholder = NSImageView(image: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage())

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.2).cgColor
        placeholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        placeholder.contentTintColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // clicking the artwork opens the player (set by the controller)
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func show(_ image: NSImage?) {
        let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contents = cg
        placeholder.isHidden = cg != nil
    }
}

// MARK: - Recently played

// One row of the Recently Played list. Small and Codable so the whole list fits in UserDefaults as JSON.
// The link and the player's ids are kept so clicking a row can go back to that song later.
struct Track: Codable {
    var title: String
    var artist: String
    var url: String?
    var bundleID: String?
    var pid: Int32?
    var plays: Int

    var line: String {
        let base = artist.isEmpty ? title : "\(title) — \(artist)"
        return plays > 1 ? "\(base)  ×\(plays)" : base
    }
}

// Newest first, de-duplicated by title+artist: every observed play moves to the top and increments its lifetime count.
// The full aggregate history is retained so steering can detect repeats across the entire listening history.
enum History {
    static let shown = 10
    static let kept = Int.max
    private static let key = "recentlyPlayed"
    // swapped by --history-test so the check never touches the real list
    static var store = UserDefaults.standard

    private(set) static var tracks: [Track] = load()

    static func load() -> [Track] {
        guard let data = store.data(forKey: key),
              let list = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        return list
    }

    static func save() { store.set(try? JSONEncoder().encode(tracks), forKey: key) }

    // re-reads the current store (used after the snapshot swaps it for a throwaway suite and back)
    static func reload() { tracks = load() }

    static func add(title: String, artist: String, url: String?, bundleID: String?, pid: Int32?) {
        guard !title.isEmpty else { return }
        if let i = tracks.firstIndex(where: { $0.title == title && $0.artist == artist }) {
            var t = tracks.remove(at: i)
            t.plays += 1
            t.url = url ?? t.url  // a play that could not resolve a link keeps the one already stored
            t.bundleID = bundleID
            t.pid = pid
            tracks.insert(t, at: 0)
        } else {
            tracks.insert(Track(title: title, artist: artist, url: url, bundleID: bundleID, pid: pid, plays: 1), at: 0)
        }
        tracks = Array(tracks.prefix(kept))
        save()
    }

    static func clear() {
        tracks = []
        save()
    }

    // Swaps the track at `index` with the current song (index 0).
    // The clicked track moves to the top; the current song takes the clicked track's old position.
    static func swapWithCurrent(at index: Int) {
        guard index > 0, index < tracks.count else { return }
        tracks.swapAt(0, index)
        save()
    }

    // Throwaway defaults suite the checks run against, so they never touch the real list.
    static let testSuite = "com.quan.songnotifier.history-test"

    // Exercises the store the menu reads: `<app>/Contents/MacOS/song-notifier --history-test`
    static func selfTest() {
        func check(_ ok: Bool, _ what: String) { print("\(ok ? "ok  " : "FAIL")  \(what)") }
        let name = testSuite
        store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        tracks = []
        add(title: "A", artist: "X", url: "https://example.com/a", bundleID: "b", pid: 1)
        add(title: "B", artist: "Y", url: nil, bundleID: "b", pid: 1)
        add(title: "A", artist: "X", url: nil, bundleID: "b", pid: 1)
        check(tracks.count == 2, "playing 2 songs (one twice) gives 2 rows")
        check(tracks.first?.title == "A" && tracks.first?.plays == 2, "a repeat moves to the top and counts a play")
        check(tracks.first?.url == "https://example.com/a", "a repeat with no link keeps the stored one")
        check(load().count == tracks.count, "survives a reload (persisted)")
        check(load().first?.url == "https://example.com/a", "the stored link survives a reload")
        for i in 0..<40 { add(title: "S\(i)", artist: "", url: nil, bundleID: nil, pid: nil) }
        check(tracks.count == 42, "retains the full lifetime aggregate history")
        check(tracks.first?.title == "S39", "newest first")
        clear()
        check(tracks.isEmpty && load().isEmpty, "clear empties the list")
        store.removePersistentDomain(forName: name)
        store = UserDefaults.standard
    }
}

// MARK: - media-control helper

// build.sh bundles media-control into the app, so users never install it separately.
let mediaControlURL = Bundle.main.resourceURL?.appendingPathComponent("media-control/bin/media-control")

// MARK: - Soundwave

// Five small equalizer bars (pink → violet, like the icon badge) that bounce while music plays
// and rest as short bars when it is paused. Driven by a timer that only runs while the view is on
// screen and playing: Core Animation animations get dropped whenever a menu closes.
final class WaveView: NSView {
    private let bars: [CALayer] = (0..<5).map { _ in CALayer() }
    private let barWidth: CGFloat = 3, barGap: CGFloat = 3
    private let rest: [CGFloat] = Array(repeating: 0.22, count: 5)
    private let periods: [Double] = [0.55, 0.80, 0.65, 0.95, 0.70]  // seconds per up-down cycle
    private let lows: [CGFloat] = [0.25, 0.15, 0.30, 0.20, 0.28]
    private let highs: [CGFloat] = [0.85, 1.00, 0.70, 0.95, 0.80]
    private var timer: Timer?

    var isActive = false {
        didSet { if oldValue != isActive { sync() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (i, bar) in bars.enumerated() {
            let t = CGFloat(i) / CGFloat(bars.count - 1)
            bar.backgroundColor = NSColor(srgbRed: 1.0 + (0.55 - 1.0) * t, green: 0.45 + (0.35 - 0.45) * t,
                                          blue: 0.70 + (0.95 - 0.70) * t, alpha: 1).cgColor
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
        }
        setLevels(rest)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * barGap, height: 22)
    }

    override func layout() {
        super.layout()
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: barWidth / 2 + CGFloat(i) * (barWidth + barGap), y: bounds.midY)
        }
    }

    // the menu detaches/re-attaches its views every time it closes/opens
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sync()
    }

    private func sync() {
        if isActive && window != nil {
            guard timer == nil else { return }
            // .common so it keeps firing while the menu is open (event-tracking run loop mode)
            let t = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            setLevels(rest)
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        setLevels((0..<bars.count).map { i in
            let wave = 0.5 + 0.5 * sin(now / periods[i] * 2 * .pi + Double(i) * 1.1)
            return lows[i] + (highs[i] - lows[i]) * CGFloat(wave)
        })
    }

    // bar heights as 0...1 fractions of the view height (also used by the --snapshot layout check)
    func setLevels(_ levels: [CGFloat]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, levels) { bar.transform = CATransform3DMakeScale(1, level, 1) }
        CATransaction.commit()
    }
}

// MARK: - App

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let un = UNUserNotificationCenter.current()

    // Now Playing state is fed by `media-control stream` (brew install ungive/media-control/media-control),
    // which reports whatever macOS considers "now playing": browsers, Apple Music, Spotify, ...
    var state: [String: Any] = [:]
    var lastTrack = ""
    var pending: DispatchWorkItem?
    var helper: Process?
    var steeringLastAction = Date.distantPast
    let steeringCooldown: TimeInterval = 45
    // Automatic steering is only allowed immediately after a track starts; never interrupt a song mid-playback.
    var currentTrackStartedAt = Date.distantPast
    let steeringWindow: TimeInterval = 5
    var buffer = Data()

    // menu bar
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var statusMenu = NSMenu()
    var playPauseButton: NSButton?
    var seekSlider: NSSlider?
    // Position the user picked on the slider, shown instead of the player's until the player catches up.
    // seekCommittedAt is nil while the mouse is still down (a preview), set once the seek was sent.
    var seekTarget: Double?
    var seekCommittedAt: Date?
    var seekPickedAt = Date.distantPast
    var elapsedLabel: NSTextField?
    var remainingLabel: NSTextField?
    let artworkView = ArtworkView(frame: .zero)
    let waveView = WaveView(frame: .zero)
    let titleLabel = NSTextField(wrappingLabelWithString: "Not playing")
    let artistLabel = NSTextField(labelWithString: "")
    let popupsMenuItem = NSMenuItem(title: "Show popups", action: #selector(togglePopupsFromMenu), keyEquivalent: "")
    // Recently Played: the rows are rebuilt in menuWillOpen, so the menu never changes while it is closed.
    let recentMenuItem = NSMenuItem(title: "Recently Played", action: nil, keyEquivalent: "")
    let recentMenu = NSMenu()
    // Recommendations: fetched from Last.fm on menu open (cached for 10 min).
    let recommendMenuItem = NSMenuItem(title: "Recommendations", action: nil, keyEquivalent: "")
    let recommendMenu = NSMenu()
    let youtubeMenuItem = NSMenuItem(title: "YouTube categories", action: nil, keyEquivalent: "")
    let youtubeMenu = NSMenu()
    var lastRecommendationFetch: Date = .distantPast
    var cachedRecommendations: [(title: String, artist: String, spotifyUri: String?)] = []
    // Banner width = 28 characters of a monospaced font (so the rolling text doesn't jiggle the bar) times
    // the size chosen in Settings.
    static let sizes: [(label: String, scale: Double)] = [("1x", 1.0), ("0.8x", 0.8), ("0.5x", 0.5)]
    var menuBarScale: Double {
        let v = UserDefaults.standard.double(forKey: "menuBarScale")
        return Controller.sizes.contains { $0.scale == v } ? v : 1.0
    }
    var menuBarChars: Int { Int((28 * menuBarScale).rounded()) }
    var scrollOffset = 0
    var ticker: Timer?
    var progressTimer: Timer?

    // settings window
    var window: NSWindow?
    var loginBox: NSButton?
    var loginNote: NSTextField?
    var popupsBox: NSButton?
    var settingsStack: NSStackView?
    var sizeControl: NSSegmentedControl?
    var spotifyClientIdField: NSTextField?
    var spotifyClientSecretField: NSTextField?
    var lastfmApiKeyField: NSTextField?
    var lastfmUserField: NSTextField?

    var isPlaying: Bool { (state["playing"] as? Bool) == true }
    var songLine: String {
        guard let title = state["title"] as? String, !title.isEmpty else { return "" }
        let artist = state["artist"] as? String ?? ""
        return artist.isEmpty ? title : "\(title) — \(artist)"
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(into: CommandLine.arguments[i + 1])  // layout QA: `song-notifier --snapshot <dir>`
            exit(0)
        }
        if historyTestMode {
            History.selfTest()  // store QA: `song-notifier --history-test`
            recordTest()        // detection QA: stream lines in, list rows out
            exit(0)
        }
        if focusTestMode {
            focusTest()         // navigation QA: is the browser tab playing the song found?
            exit(0)
        }
        un.delegate = self
        un.requestAuthorization(options: [.alert]) { granted, err in
            print("notification permission granted:", granted, err?.localizedDescription ?? "")
        }

        // Set up a main menu with Edit menu for keyboard shortcuts (Cmd+C/V/X/A/Z)
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        statusMenu = makeStatusMenu()
        statusItem.menu = statusMenu
        statusItem.button?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.scrollOffset += 1
            self?.refreshMenuBar()
        }
        progressTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshPlaybackProgress()
        }
        if let progressTimer { RunLoop.main.add(progressTimer, forMode: .common) }
        refreshMenuBar()

        // don't leave the helper orphaned when we are stopped
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigtermSource = term

        startStream()

        // first run: let the user pick settings (e.g. Launch at login) instead of silently doing things
        if !UserDefaults.standard.bool(forKey: "configured") {
            UserDefaults.standard.set(true, forKey: "configured")
            showSettings()
        }
        print("Listening for song changes via macOS Now Playing.")
    }
    var sigtermSource: DispatchSourceSignal?

    func applicationWillTerminate(_ n: Notification) { helper?.terminate() }

    // Opening the app again (Finder, `open`) while it runs brings up the settings: the way back
    // in when the menu bar item is hidden.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: notifications

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
    }

    func notify(title: String, body: String, player: [String: Any]) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = player
        un.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: now-playing stream

    func startStream() {
        guard let tool = mediaControlURL else { print("bundled media-control not found"); return }
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = ["stream"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil; return }  // helper died; terminationHandler restarts it
            DispatchQueue.main.async { self?.feed(chunk) }
        }
        // launchd used to restart us if the helper died; now we restart the helper
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.startStream() }
        }
        do { try proc.run(); helper = proc } catch { print("cannot start media-control:", error) }
    }

    func feed(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
            buffer.removeSubrange(...nl)
            handle(line: line)
        }
    }

    func handle(line: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        let titleBefore = state["title"] as? String
        if (obj["diff"] as? Bool) == true {
            for (k, v) in payload { if v is NSNull { state[k] = nil } else { state[k] = v } }
        } else {
            state = payload
        }
        updateArtwork(payload: payload, isDiff: (obj["diff"] as? Bool) == true, titleChanged: titleBefore != state["title"] as? String)
        scrollOffset = 0
        refreshMenuBar()
        scheduleNotify()
    }

    // artworkData is a base64 image. A diff without it keeps the old artwork unless the track changed.
    func updateArtwork(payload: [String: Any], isDiff: Bool, titleChanged: Bool) {
        if let b64 = payload["artworkData"] as? String {
            artworkView.show(Data(base64Encoded: b64).flatMap { NSImage(data: $0) })
        } else if !isDiff || payload["artworkData"] is NSNull || titleChanged {
            artworkView.show(nil)
        }
    }

    // Browsers publish the title first and artist/album a moment later (sometimes a second title tweak too).
    // Wait for the metadata to settle, then notify once per track (keyed on title only).
    func scheduleNotify() {
        pending?.cancel()
        let work = DispatchWorkItem { [self] in
            guard isPlaying, let name = state["title"] as? String, !name.isEmpty, name != lastTrack else { return }
            lastTrack = name
            currentTrackStartedAt = Date()
            let artist = state["artist"] as? String ?? ""
            let album = state["album"] as? String ?? ""
            let bundleID = state["bundleIdentifier"] as? String
            let pid = state["processIdentifier"] as? Int32
            let repeatedPreviously = History.tracks.contains {
                $0.title == name && $0.artist == artist
            }
            // Record every observed play before steering, including tracks that are redirected.
            // The full lifetime count is independent of the Recently Played visibility setting.
            History.add(title: name, artist: artist, url: playingURL(bundleID: bundleID, title: name),
                        bundleID: bundleID, pid: pid)
            if Flag.steerListening.isOn && repeatedPreviously &&
               Date().timeIntervalSince(currentTrackStartedAt) <= steeringWindow &&
               Date().timeIntervalSince(steeringLastAction) > steeringCooldown {
                steeringLastAction = Date()
                print("Steering away from repeated track: \(name) — \(artist)")
                control("next-track")
                return
            }
            guard Flag.showPopups.isOn else { return }
            var player: [String: Any] = ["title": name]
            player["bundleID"] = bundleID
            player["pid"] = pid
            notify(title: name, body: [artist, album].filter { !$0.isEmpty }.joined(separator: " — "), player: player)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: music controls (media-control talks to whatever app owns Now Playing)

    func control(_ command: String) {
        guard let tool = mediaControlURL else { return }
        let p = Process()
        p.executableURL = tool
        p.arguments = [command]
        try? p.run()
    }

    // Now-playing card at the top of the menu: artwork on the left; on the right the title and artist are
    // pinned to the artwork's top edge and the ⏮ ⏯ ⏭ icon buttons to its bottom edge, so both columns share
    // top and bottom lines. Play/pause is the biggest control. Clicking a button doesn't close the menu, so the
    // play/pause icon can be seen flipping. Menu item views get a fixed frame, hence the fixed sizes.
    func makeCard() -> NSView {
        let textWidth: CGFloat = 220, art: CGFloat = 96, pad: CGFloat = 16, gap: CGFloat = 14

        func button(_ symbol: String, _ tip: String, _ action: Selector, size: CGFloat, width: CGFloat) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            b.contentTintColor = .labelColor
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return b
        }
        let playPause = button("play.fill", "Play / Pause", #selector(togglePlayPause), size: 28, width: 44)
        playPauseButton = playPause
        let controls = NSStackView(views: [button("backward.fill", "Previous", #selector(previousTrack), size: 17, width: 32),
                                           playPause,
                                           button("forward.fill", "Next", #selector(nextTrack), size: 17, width: 32)])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.distribution = .equalSpacing  // spread ⏮ ⏯ ⏭ and the soundwave evenly across the text column
        waveView.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(waveView)
        waveView.widthAnchor.constraint(equalToConstant: waveView.intrinsicContentSize.width).isActive = true
        waveView.heightAnchor.constraint(equalToConstant: waveView.intrinsicContentSize.height).isActive = true
        controls.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.allowsTickMarkValuesOnly = false
        slider.numberOfTickMarks = 0
        slider.toolTip = "Seek"
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.translatesAutoresizingMaskIntoConstraints = false
        seekSlider = slider
        let elapsed = NSTextField(labelWithString: "0:00")
        let remaining = NSTextField(labelWithString: "-0:00")
        for label in [elapsed, remaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        elapsedLabel = elapsed
        remainingLabel = remaining

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping  // wrap first; truncating mode would stop at one line
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.preferredMaxLayoutWidth = textWidth
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        for l in [titleLabel, artistLabel] { l.translatesAutoresizingMaskIntoConstraints = false }
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.toolTip = "Open the player"
        artworkView.onClick = { [weak self] in self?.openPlayer() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: pad + art + gap + textWidth + pad, height: art + 2 * pad))
        for v in [artworkView, titleLabel, artistLabel, controls, slider, elapsed, remaining] { container.addSubview(v) }
        let textLeading = artworkView.trailingAnchor
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            artworkView.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            artworkView.widthAnchor.constraint(equalToConstant: art),
            artworkView.heightAnchor.constraint(equalToConstant: art),

            titleLabel.leadingAnchor.constraint(equalTo: textLeading, constant: gap),
            titleLabel.widthAnchor.constraint(equalToConstant: textWidth),
            titleLabel.topAnchor.constraint(equalTo: artworkView.topAnchor, constant: -1),  // optical: cap height meets the artwork top
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.widthAnchor.constraint(equalToConstant: textWidth),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.bottomAnchor.constraint(lessThanOrEqualTo: slider.topAnchor, constant: -2),

            // the first glyph sits ~3pt inside its button; shift the row left so the glyph lines up with the text
            controls.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -3),
            controls.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 2),
            slider.leadingAnchor.constraint(equalTo: elapsed.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: remaining.leadingAnchor, constant: -6),
            slider.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -2),
            elapsed.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            elapsed.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            remaining.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            remaining.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        ])
        slider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return container
    }

    @objc func seekChanged(_ slider: NSSlider) {
        guard let duration = state["duration"] as? Double, duration > 0 else { return }
        let target = slider.doubleValue * duration
        seekTarget = target
        seekPickedAt = Date()
        // Mouse down / drag only preview the position; the seek is sent once, on release.
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDown || type == .leftMouseDragged {
            seekCommittedAt = nil
        } else {
            seekCommittedAt = Date()
            control("seek", argument: target)
        }
        refreshPlaybackProgress()
    }

    func control(_ command: String, argument: Double) {
        guard let tool = mediaControlURL else { return }
        let p = Process()
        p.executableURL = tool
        // media-control rejects any number written as "0.x" (it parses ".5"), so seek in whole seconds.
        p.arguments = [command, String(max(0, Int(argument.rounded())))]
        try? p.run()
    }

    // Artwork clicked: close the menu and bring the player (and, for browsers, the song's tab) to the front.
    func openPlayer() {
        statusItem.menu?.cancelTracking()
        focusPlayer(bundleID: state["bundleIdentifier"] as? String,
                    pid: state["processIdentifier"] as? Int32,
                    title: state["title"] as? String)
    }

    @objc func previousTrack() { control("previous-track") }
    @objc func nextTrack() { control("next-track") }
    @objc func togglePlayPause() { control("toggle-play-pause") }

    // MARK: menu bar

    // The whole status menu. Called once at launch (and once by --snapshot): it hands the stored menu items
    // to the menu, and an NSMenuItem can only live in one menu, so a second call raises from addItem.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let card = NSMenuItem()
        card.view = makeCard()
        menu.addItem(card)
        menu.addItem(.separator())
        popupsMenuItem.target = self
        popupsMenuItem.state = Flag.showPopups.isOn ? .on : .off
        menu.addItem(popupsMenuItem)
        recentMenuItem.submenu = recentMenu
        recentMenu.delegate = self
        menu.addItem(recentMenuItem)
        recommendMenuItem.submenu = recommendMenu
        recommendMenu.delegate = self
        menu.addItem(recommendMenuItem)
        youtubeMenuItem.submenu = youtubeMenu
        youtubeMenu.delegate = self
        menu.addItem(youtubeMenuItem)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Song Notifier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    // Rebuilt on every open: the rows always match History, without touching the menu while it is closed.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === recentMenu {
            recentMenu.removeAllItems()
            let recent = Array(History.tracks.prefix(History.shown))
            if recent.isEmpty {
                let empty = NSMenuItem(title: "Nothing played yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                recentMenu.addItem(empty)
            }
            for t in recent {
                let item = NSMenuItem(title: t.line, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t
                item.toolTip = "Open the player"
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Recently Played", action: #selector(clearRecent), keyEquivalent: "")
            clear.target = self
            clear.isEnabled = !recent.isEmpty
            recentMenu.addItem(clear)
        } else if menu === recommendMenu {
            buildRecommendationsMenu()
        } else if menu === youtubeMenu {
            buildYouTubeCategoriesMenu()
        }
    }

    func buildYouTubeCategoriesMenu() {
        youtubeMenu.removeAllItems()
        let categories = [
            ("All", "https://www.youtube.com/results?search_query=music"),
            ("From same artist", "https://www.youtube.com/results?search_query=" + ((state["artist"] as? String ?? "music").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "music")),
            ("Youth music", "https://www.youtube.com/results?search_query=youth+music"),
            ("Rapping", "https://www.youtube.com/results?search_query=rapping+music"),
            ("Related", "https://www.youtube.com/results?search_query=related+music"),
            ("For you", "https://www.youtube.com/feed/personalized"),
            ("Recently uploaded", "https://www.youtube.com/results?sp=CAI%253D")
        ]
        for (title, address) in categories {
            let item = NSMenuItem(title: title, action: #selector(openYouTubeCategory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = address
            youtubeMenu.addItem(item)
        }
    }

    func openYouTubeCategory(at index: Int, artist: String) {
        let queryArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "music"
        let addresses = [
            "https://www.youtube.com/results?search_query=music",
            "https://www.youtube.com/results?search_query=\(queryArtist)",
            "https://www.youtube.com/results?search_query=youth+music",
            "https://www.youtube.com/results?search_query=rapping+music",
            "https://www.youtube.com/results?search_query=related+music",
            "https://www.youtube.com/feed/personalized",
            "https://www.youtube.com/results?sp=CAI%253D"
        ]
        guard addresses.indices.contains(index), let url = URL(string: addresses[index]) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openYouTubeCategory(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String,
              let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    // Clicking a row swaps it with the current song (index 0), then goes back to that song:
    // the tab is selected if it is still open, otherwise the link stored with the row is opened.
    // Returns true when the song was reached.
    @discardableResult
    @objc func openRecent(_ item: NSMenuItem) -> Bool {
        guard let t = item.representedObject as? Track else { return false }
        // swap the clicked row with the current song (index 0)
        if let idx = History.tracks.firstIndex(where: { $0.title == t.title && $0.artist == t.artist }) {
            History.swapWithCurrent(at: idx)
        }
        if focusPlayer(bundleID: t.bundleID, pid: t.pid, title: t.title) { return true }
        guard let url = t.url, let target = URL(string: url) else { return false }
        return openInPlayer(target, bundleID: t.bundleID)
    }

    // Opens a link in the browser that played the song, or in the default browser when it is not running.
    func openInPlayer(_ target: URL, bundleID: String?) -> Bool {
        guard let bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let appURL = app.bundleURL else { return NSWorkspace.shared.open(target) }
        app.activate()
        NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return true
    }

    @objc func clearRecent() { History.clear() }

    // MARK: - Recommendations from Last.fm

    func buildRecommendationsMenu() {
        recommendMenu.removeAllItems()

        // Use cache if fresh (< 10 minutes old)
        if Date().timeIntervalSince(lastRecommendationFetch) < 600 && !cachedRecommendations.isEmpty {
            populateRecommendationsMenu()
            return
        }

        // Show loading state
        let loading = NSMenuItem(title: "Loading recommendations…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        recommendMenu.addItem(loading)

        // Fetch from Last.fm in background
        fetchLastFMRecommendations { [weak self] recommendations in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cachedRecommendations = recommendations
                self.lastRecommendationFetch = Date()
                self.populateRecommendationsMenu()
            }
        }
    }

    func populateRecommendationsMenu() {
        recommendMenu.removeAllItems()

        if cachedRecommendations.isEmpty {
            let empty = NSMenuItem(title: "No recommendations available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recommendMenu.addItem(empty)
            return
        }

        for rec in cachedRecommendations {
            let title = rec.title.isEmpty ? "Unknown" : rec.title
            let artist = rec.artist.isEmpty ? "Unknown Artist" : rec.artist
            let displayText = "\(title) — \(artist)"

            let item = NSMenuItem(title: displayText, action: #selector(openRecommendation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rec
            item.toolTip = "Play in music player"
            recommendMenu.addItem(item)
        }

        recommendMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Recommendations", action: #selector(refreshRecommendations), keyEquivalent: "")
        refresh.target = self
        recommendMenu.addItem(refresh)
    }

    @objc func openRecommendation(_ sender: NSMenuItem) {
        guard let rec = sender.representedObject as? (title: String, artist: String, spotifyUri: String?) else { return }
        
        if let spotifyUri = rec.spotifyUri, !spotifyUri.isEmpty {
            // Check if Spotify app is installed
            if let spotifyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                // Spotify app is installed, open in app using URI scheme
                if let url = URL(string: spotifyUri) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                // Spotify app not installed, open in web player
                openSpotifyWebTrack(uri: spotifyUri)
            }
        } else {
            // No Spotify URI, open web search
            openSpotifyWebSearch(query: "\(rec.title) \(rec.artist)")
        }
    }
    
    private func openSpotifyWebTrack(uri: String) {
        // Convert spotify:track:xxx to https://open.spotify.com/track/xxx
        let trackId = uri.replacingOccurrences(of: "spotify:track:", with: "")
        let webURL = "https://open.spotify.com/track/\(trackId)"
        if let url = URL(string: webURL) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openSpotifyWebSearch(query: String) {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = "https://open.spotify.com/search/\(encodedQuery)"
        if let url = URL(string: searchURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func refreshRecommendations() {
        lastRecommendationFetch = .distantPast
        buildRecommendationsMenu()
    }

    @objc func saveLastfmCredentials() {
        let apiKey = lastfmApiKeyField?.stringValue ?? ""
        let user = lastfmUserField?.stringValue ?? ""
        UserDefaults.standard.set(apiKey, forKey: "lastfmApiKey")
        UserDefaults.standard.set(user, forKey: "lastfmUser")
        
        let alert = NSAlert()
        alert.messageText = "Last.fm Credentials Saved"
        alert.informativeText = "Your Last.fm API credentials have been saved successfully."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!) { _ in }
    }

    @objc func saveSpotifyCredentials() {
        let clientId = spotifyClientIdField?.stringValue ?? ""
        let clientSecret = spotifyClientSecretField?.stringValue ?? ""
        
        UserDefaults.standard.set(clientId, forKey: "spotifyClientId")
        UserDefaults.standard.set(clientSecret, forKey: "spotifyClientSecret")
        
        let alert = NSAlert()
        alert.messageText = "Spotify Credentials Saved"
        alert.informativeText = "Your Spotify API credentials have been saved successfully."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!) { _ in }
    }

    func fetchLastFMRecommendations(completion: @escaping ([(title: String, artist: String, spotifyUri: String?)]) -> Void) {
        let lastfmAPIKey = UserDefaults.standard.string(forKey: "lastfmApiKey") ?? ""
        let lastfmUser = UserDefaults.standard.string(forKey: "lastfmUser") ?? ""
        
        guard !lastfmAPIKey.isEmpty && !lastfmUser.isEmpty else {
            completion([])
            return
        }
        
        let encodedUser = lastfmUser.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? lastfmUser
        let recentURL = "https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=\(encodedUser)&api_key=\(lastfmAPIKey)&format=json&limit=20"

        guard let url = URL(string: recentURL) else {
            completion([])
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                completion([])
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let recentTracks = json["recenttracks"] as? [String: Any],
                      let tracks = recentTracks["track"] as? [[String: Any]] else {
                    completion([])
                    return
                }

                // Extract unique artists from recent tracks
                var seenArtists = Set<String>()
                var artists: [String] = []
                for track in tracks {
                    let artistInfo = track["artist"] as? [String: Any]
                    let artist = artistInfo?["#text"] as? String ?? ""
                    if !artist.isEmpty && !seenArtists.contains(artist) {
                        seenArtists.insert(artist)
                        artists.append(artist)
                    }
                    if artists.count >= 3 { break }  // Use up to 3 artists as seeds
                }

                guard !artists.isEmpty else {
                    completion([])
                    return
                }

                // Fetch similar artists and their top tracks in parallel
                let group = DispatchGroup()
                var allRecommendations: [(title: String, artist: String, spotifyUri: String?)] = []
                let lock = NSLock()

                for artist in artists {
                    group.enter()
                    let encArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artist
                    let similarArtistsURL = "https://ws.audioscrobbler.com/2.0/?method=artist.getsimilar&artist=\(encArtist)&api_key=\(lastfmAPIKey)&format=json&limit=3"

                    guard let simArtURL = URL(string: similarArtistsURL) else {
                        group.leave()
                        continue
                    }

                    URLSession.shared.dataTask(with: simArtURL) { simData, _, _ in
                        defer { group.leave() }
                        guard let simData = simData,
                              let simJSON = try? JSONSerialization.jsonObject(with: simData, options: []) as? [String: Any],
                              let similar = simJSON["similarartists"] as? [String: Any],
                              let simArtists = similar["artist"] as? [[String: Any]] else { return }

                        // For each similar artist, fetch their top tracks
                        for simArtist in simArtists.prefix(2) {
                            let simArtistName = simArtist["name"] as? String ?? ""
                            guard !simArtistName.isEmpty else { continue }

                            group.enter()
                            let encSimArtist = simArtistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? simArtistName
                            let topTracksURL = "https://ws.audioscrobbler.com/2.0/?method=artist.gettoptracks&artist=\(encSimArtist)&api_key=\(lastfmAPIKey)&format=json&limit=3"

                            guard let topURL = URL(string: topTracksURL) else {
                                group.leave()
                                continue
                            }

                            URLSession.shared.dataTask(with: topURL) { topData, _, _ in
                                defer { group.leave() }
                                guard let topData = topData,
                                      let topJSON = try? JSONSerialization.jsonObject(with: topData, options: []) as? [String: Any],
                                      let topTracks = topJSON["toptracks"] as? [String: Any],
                                      let topList = topTracks["track"] as? [[String: Any]] else { return }

                                for tt in topList {
                                    let name = tt["name"] as? String ?? ""
                                    let ttURL = tt["url"] as? String ?? ""
                                    guard !name.isEmpty else { continue }

                                    lock.lock()
                                    if !allRecommendations.contains(where: { $0.title == name && $0.artist == simArtistName }) {
                                        allRecommendations.append((title: name, artist: simArtistName, spotifyUri: nil))
                                    }
                                    lock.unlock()
                                }
                            }.resume()
                        }
                    }.resume()
                }

                group.notify(queue: .main) {
                    // Now search Spotify for each recommendation to get track URIs
                    let spotifyGroup = DispatchGroup()
                    
                    // Get Spotify credentials from UserDefaults
                    let clientId = UserDefaults.standard.string(forKey: "spotifyClientId") ?? ""
                    let clientSecret = UserDefaults.standard.string(forKey: "spotifyClientSecret") ?? ""
                    
                    guard !clientId.isEmpty && !clientSecret.isEmpty else {
                        completion(Array(allRecommendations.prefix(15)))
                        return
                    }
                    
                    // First get Spotify access token
                    let tokenURL = "https://accounts.spotify.com/api/token"
                    var request = URLRequest(url: URL(string: tokenURL)!)
                    request.httpMethod = "POST"
                    let credentials = "\(clientId):\(clientSecret)"
                    let base64Credentials = credentials.data(using: .utf8)!.base64EncodedString()
                    request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = "grant_type=client_credentials".data(using: .utf8)
                    
                    URLSession.shared.dataTask(with: request) { tokenData, _, _ in
                        guard let tokenData = tokenData,
                              let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData, options: []) as? [String: Any],
                              let accessToken = tokenJSON["access_token"] as? String else {
                            completion(Array(allRecommendations.prefix(15)))
                            return
                        }
                        
                        // Search for each track
                        for i in 0..<allRecommendations.count {
                            spotifyGroup.enter()
                            let rec = allRecommendations[i]
                            let query = "\(rec.title) \(rec.artist)"
                            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            let searchURL = "https://api.spotify.com/v1/search?q=\(encodedQuery)&type=track&limit=1"
                            
                            var searchRequest = URLRequest(url: URL(string: searchURL)!)
                            searchRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                            
                            URLSession.shared.dataTask(with: searchRequest) { searchData, _, _ in
                                defer { spotifyGroup.leave() }
                                guard let searchData = searchData,
                                      let searchJSON = try? JSONSerialization.jsonObject(with: searchData, options: []) as? [String: Any],
                                      let tracks = searchJSON["tracks"] as? [String: Any],
                                      let items = tracks["items"] as? [[String: Any]],
                                      let firstTrack = items.first,
                                      let uri = firstTrack["uri"] as? String else { return }
                                
                                lock.lock()
                                allRecommendations[i] = (title: rec.title, artist: rec.artist, spotifyUri: uri)
                                lock.unlock()
                            }.resume()
                        }
                        
                        spotifyGroup.notify(queue: .main) {
                            completion(Array(allRecommendations.prefix(15)))
                        }
                    }.resume()
                }
            } catch {
                completion([])
            }
        }

        task.resume()
    }


    func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    // Stream updates provide elapsedTime and timestamp; calculate live progress between updates.
    func currentElapsedTime() -> Double? {
        if let value = state["elapsedTimeNow"] as? Double { return value }
        guard let elapsed = state["elapsedTime"] as? Double,
              let timestamp = state["timestamp"] as? String,
              let date = ISO8601DateFormatter().date(from: timestamp) else { return nil }
        let rate = state["playbackRate"] as? Double ?? 1
        return elapsed + max(0, Date().timeIntervalSince(date)) * rate
    }

    // The only place that writes the slider and its time labels, so nothing can fight the user's pick.
    func refreshPlaybackProgress() {
        guard let duration = state["duration"] as? Double, duration > 0 else {
            seekTarget = nil
            seekCommittedAt = nil
            seekSlider?.doubleValue = 0
            seekSlider?.isEnabled = false
            elapsedLabel?.stringValue = "0:00"
            remainingLabel?.stringValue = "-0:00"
            return
        }
        let live = currentElapsedTime().map { min(max($0, 0), duration) }
        var shown = live ?? 0
        if let target = seekTarget {
            // Hold the picked position until the player reports it. Give up after 5 s (a seek the player ignored,
            // or a menu that closed mid-drag) so the slider can never stay stuck.
            let arrived = seekCommittedAt != nil && (live.map { abs($0 - target) < 2.5 } ?? false)
            if arrived || Date().timeIntervalSince(seekPickedAt) > 5 {
                seekTarget = nil
                seekCommittedAt = nil
            } else {
                shown = min(max(target, 0), duration)
            }
        }
        seekSlider?.isEnabled = true
        // while dragging, AppKit owns the thumb
        if seekCommittedAt != nil || seekTarget == nil { seekSlider?.doubleValue = shown / duration }
        elapsedLabel?.stringValue = formatTime(shown)
        remainingLabel?.stringValue = "-\(formatTime(max(duration - shown, 0)))"
    }

    func refreshMenuBar() {
        statusItem.isVisible = Flag.showInMenuBar.isOn
        recentMenuItem.isHidden = !Flag.recentList.isOn
        let line = songLine
        let title = state["title"] as? String ?? ""
        let artist = state["artist"] as? String ?? ""
        let shownTitle = title.isEmpty ? "Not playing" : title
        if titleLabel.stringValue != shownTitle { titleLabel.stringValue = shownTitle }
        if artistLabel.stringValue != artist { artistLabel.stringValue = artist }
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Play / Pause")
        waveView.isActive = isPlaying
        refreshPlaybackProgress()
        guard statusItem.isVisible, let button = statusItem.button else { return }

        guard !line.isEmpty else { button.title = "♫"; return }
        let chars = Array(line)
        var shown: [Character]
        if chars.count <= menuBarChars {
            shown = chars
        } else if Flag.scrollTitle.isOn && isPlaying {
            let loop = chars + Array("   •   ")
            shown = (0..<menuBarChars).map { loop[(scrollOffset + $0) % loop.count] }
        } else {
            shown = Array(chars.prefix(menuBarChars - 1)) + ["…"]
        }
        shown += Array(repeating: " ", count: max(0, menuBarChars - shown.count))
        button.title = "♫ " + String(shown)
    }

    // MARK: settings window

    @objc func showSettings() {
        if window == nil { buildWindow() }
        syncLoginBox()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)  // no focus ring on the first checkbox when the window opens
    }

    // MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        // Window is closing, just let it close
        window = nil
    }

    func checkbox(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        return b
    }

    func buildWindow() {
        let login = checkbox("Launch at login", #selector(toggleLogin(_:)))
        let menubar = checkbox("Show the song in the menu bar", #selector(toggleMenuBar(_:)))
        let scroll = checkbox("Roll long titles across the menu bar", #selector(toggleScroll(_:)))
        let popups = checkbox("Show a popup when the song changes", #selector(togglePopups(_:)))
        let recent = checkbox("Keep a list of recently played songs", #selector(toggleRecent(_:)))
        let steer = checkbox("Steer away from repeated songs automatically", #selector(toggleSteering(_:)))
        menubar.state = Flag.showInMenuBar.isOn ? .on : .off
        scroll.state = Flag.scrollTitle.isOn ? .on : .off
        popups.state = Flag.showPopups.isOn ? .on : .off
        recent.state = Flag.recentList.isOn ? .on : .off
        steer.state = Flag.steerListening.isOn ? .on : .off
        popupsBox = popups
        loginBox = login

        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        loginNote = note
        let hint = NSTextField(wrappingLabelWithString:
            "Click a popup to jump to the tab or app that is playing the song. With the menu bar item hidden, open Song Notifier again to get back to this window.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let copyright = NSTextField(labelWithString: "© 2026 RedhairedQuan · Version \(version)")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .tertiaryLabelColor

        // Last.fm API credentials
        let lastfmTitle = NSTextField(labelWithString: "Last.fm API Credentials")
        lastfmTitle.font = .systemFont(ofSize: 12, weight: .medium)
        
        let lastfmApiKeyLabel = NSTextField(labelWithString: "API Key:")
        let lastfmApiKeyField = NSTextField()
        lastfmApiKeyField.isEditable = true
        lastfmApiKeyField.isSelectable = true
        lastfmApiKeyField.placeholderString = "Enter Last.fm API Key"
        lastfmApiKeyField.stringValue = UserDefaults.standard.string(forKey: "lastfmApiKey") ?? ""
        lastfmApiKeyField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        self.lastfmApiKeyField = lastfmApiKeyField
        
        let lastfmUserLabel = NSTextField(labelWithString: "Username:")
        let lastfmUserField = NSTextField()
        lastfmUserField.isEditable = true
        lastfmUserField.isSelectable = true
        lastfmUserField.placeholderString = "Enter Last.fm Username"
        lastfmUserField.stringValue = UserDefaults.standard.string(forKey: "lastfmUser") ?? ""
        lastfmUserField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        self.lastfmUserField = lastfmUserField
        
        let saveLastfmButton = NSButton(title: "Save", target: self, action: #selector(saveLastfmCredentials))
        saveLastfmButton.bezelStyle = .rounded
        
        let lastfmStack = NSStackView(views: [lastfmTitle, lastfmApiKeyLabel, lastfmApiKeyField, lastfmUserLabel, lastfmUserField, saveLastfmButton])
        lastfmStack.orientation = .vertical
        lastfmStack.alignment = .leading
        lastfmStack.spacing = 6
        
        // Spotify API credentials
        let spotifyTitle = NSTextField(labelWithString: "Spotify API Credentials")
        spotifyTitle.font = .systemFont(ofSize: 12, weight: .medium)
        
        let clientIdLabel = NSTextField(labelWithString: "Client ID:")
        let clientIdField = NSTextField()
        clientIdField.isEditable = true
        clientIdField.isSelectable = true
        clientIdField.placeholderString = "Enter Spotify Client ID"
        clientIdField.stringValue = UserDefaults.standard.string(forKey: "spotifyClientId") ?? ""
        clientIdField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        spotifyClientIdField = clientIdField
        
        let clientSecretLabel = NSTextField(labelWithString: "Client Secret:")
        let clientSecretField = NSTextField()
        clientSecretField.isEditable = true
        clientSecretField.isSelectable = true
        clientSecretField.placeholderString = "Enter Spotify Client Secret"
        clientSecretField.stringValue = UserDefaults.standard.string(forKey: "spotifyClientSecret") ?? ""
        clientSecretField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        spotifyClientSecretField = clientSecretField
        
        let saveSpotifyButton = NSButton(title: "Save", target: self, action: #selector(saveSpotifyCredentials))
        saveSpotifyButton.bezelStyle = .rounded
        
        let spotifyStack = NSStackView(views: [spotifyTitle, clientIdLabel, clientIdField, clientSecretLabel, clientSecretField, saveSpotifyButton])
        spotifyStack.orientation = .vertical
        spotifyStack.alignment = .leading
        spotifyStack.spacing = 6
        
        // menu bar size presets, indented to line up with the checkbox titles above
        let sizeTitle = NSTextField(labelWithString: "Menu bar size")
        let size = NSSegmentedControl(labels: Controller.sizes.map { $0.label }, trackingMode: .selectOne,
                                      target: self, action: #selector(sizeChanged(_:)))
        size.selectedSegment = Controller.sizes.firstIndex { $0.scale == menuBarScale } ?? 0
        size.isEnabled = Flag.showInMenuBar.isOn
        sizeControl = size
        let widthRow = NSStackView(views: [sizeTitle, size])
        widthRow.orientation = .horizontal
        widthRow.alignment = .centerY
        widthRow.spacing = 12
        widthRow.edgeInsets = NSEdgeInsets(top: 0, left: 21, bottom: 0, right: 0)

        let stack = NSStackView(views: [login, note, menubar, scroll, widthRow, popups, recent, steer, lastfmStack, spotifyStack, hint, copyright])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: login)  // group break; tightened to 2 while the note below it is shown
        stack.setCustomSpacing(16, after: note)
        settingsStack = stack
        note.isHidden = true  // only shown when there is something to say; hidden views take no space
        stack.setCustomSpacing(16, after: hint)
        // wrapping labels need a real width, or the window grows to the text and the right inset disappears
        for label in [hint, note] { label.widthAnchor.constraint(equalToConstant: 304).isActive = true }

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Song Notifier"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.level = .normal
        // explicit margins: the window sizes itself from this container, and NSStackView's own insets
        // left the right-hand margin out of its fitting size
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.setContentSize(content.fittingSize)
        w.center()
        window = w
    }

    // What macOS reports as now playing right now (`media-control get`), or nil when nothing is.
    func nowPlaying() -> [String: Any]? {
        guard let tool = mediaControlURL else { print("bundled media-control not found"); return nil }
        let p = Process()
        p.executableURL = tool
        p.arguments = ["get"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile())) as? [String: Any]
    }

    // Drives the real detection path with synthetic stream lines (JSON in -> list row out), so the whole
    // chain is checked without playing music. Run by --history-test, after History.selfTest().
    func recordTest() {
        func check(_ ok: Bool, _ what: String) { print("\(ok ? "ok  " : "FAIL")  \(what)") }
        let name = History.testSuite + ".record"
        History.store = UserDefaults(suiteName: name)!
        History.store.removePersistentDomain(forName: name)
        History.clear()
        let popups = Flag.showPopups.isOn
        Flag.showPopups.set(false)  // the check must not fire real notification banners
        for (n, title) in ["Test Song A", "Test Song B"].enumerated() {
            // real stream lines, exactly as media-control writes them
            handle(line: #"{"diff":false,"payload":{"playing":true,"title":"\#(title)","artist":"Test Artist","bundleIdentifier":"com.spotify.client","processIdentifier":\#(1000 + n)}}"#)
            RunLoop.current.run(until: Date().addingTimeInterval(1.3))  // the app waits 1 s for late metadata
        }
        check(History.tracks.count == 2, "two song changes recorded 2 rows (got \(History.tracks.count))")
        check(History.tracks.first?.title == "Test Song B", "newest row is the song that played last")
        // A non-browser player has no tab to read a link from, so the row must still be recorded without one.
        check(History.tracks.first?.url == nil, "a non-browser row is recorded with no link")
        // And with a browser: the song playing right now is written through the same path, link and all.
        if let live = nowPlaying(), let liveTitle = live["title"] as? String, !liveTitle.isEmpty {
            let liveArtist = live["artist"] as? String ?? ""
            let liveBundle = live["bundleIdentifier"] as? String ?? ""
            let line = #"{"diff":false,"payload":{"playing":true,"title":"\#(liveTitle)","artist":"\#(liveArtist)","bundleIdentifier":"\#(liveBundle)","processIdentifier":1}}"#
            handle(line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(1.3))
            let row = History.tracks.first
            print("      live song:   \(liveTitle)  [\(liveBundle)]")
            print("      stored link: \(row?.url ?? "none")")
            check(row?.title == liveTitle, "the song playing now was recorded")
        } else {
            print("note  nothing is playing, so the live-link check was skipped")
        }
        Flag.showPopups.set(popups)
        statusMenu = makeStatusMenu()
        let dump = menuDump()
        check(dump.contains("Test Song B — Test Artist"), "the menu shows the recorded song")
        print(dump, terminator: "")
        History.store.removePersistentDomain(forName: name)
        History.store = UserDefaults.standard
        History.reload()
    }

    // QA: bring up whatever is playing now and report whether the browser tab was found — the same thing
    // clicking a row of Recently Played does. `song-notifier --focus-test ["<song title>"]`.
    // `--focus-test --row N` instead clicks row N of the real Recently Played list, handler and all.
    func focusTest() {
        if let ri = CommandLine.arguments.firstIndex(of: "--row"), ri + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[ri + 1]) {
            statusMenu = makeStatusMenu()
            menuWillOpen(recentMenu)  // fills in the rows, exactly as opening the menu does
            let rows = recentMenu.items.filter { $0.representedObject is Track }
            guard n >= 1, n <= rows.count else { print("row \(n) out of range (1...\(rows.count))"); return }
            print("clicking row \(n) of \(rows.count): \(rows[n - 1].title)")
            print("      link on the row: \(rows[n - 1].representedObject.flatMap { ($0 as? Track)?.url } ?? "none")")
            let actioned = openRecent(rows[n - 1])  // what AppKit calls when the row is picked
            // NSWorkspace.open is asynchronous and this process is short-lived: give the request time to
            // reach the browser before exiting, or it is dropped (the app itself stays alive, so it never is).
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            print(actioned ? "ok    the row was actioned (existing tab selected, or its stored link opened)"
                           : "note  nothing to open: no tab and no stored link for that row")
            return
        }
        // Both branches of a row click, on the song playing now: the stored link is opened with a title that
        // cannot match a tab, so this lane is the link one (the --row lane above covers the tab one).
        if CommandLine.arguments.contains("--open-url") {
            guard let live = nowPlaying(), let liveTitle = live["title"] as? String, !liveTitle.isEmpty else {
                print("nothing is playing, so there is no link to store"); return
            }
            let bundleID = live["bundleIdentifier"] as? String
            guard let url = playingURL(bundleID: bundleID, title: liveTitle) else {
                print("no link found for \"\(liveTitle)\" (is its tab still open?)"); return
            }
            let row = Track(title: "zz no tab matches this", artist: "", url: url, bundleID: bundleID, pid: nil, plays: 1)
            let item = NSMenuItem(title: row.line, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = row
            print("row link: \(url)")
            let actioned = openRecent(item)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            print(actioned ? "ok    the stored link was handed to the browser"
                           : "FAIL  the stored link was not opened")
            return
        }
        guard let now = nowPlaying() else { print("bundled media-control not found"); return }
        var title: String?
        if let i = CommandLine.arguments.firstIndex(of: "--focus-test"), i + 1 < CommandLine.arguments.count,
           !CommandLine.arguments[i + 1].hasPrefix("--") {
            title = CommandLine.arguments[i + 1]
        }
        let song = title ?? now["title"] as? String ?? ""
        let bundleID = now["bundleIdentifier"] as? String
        print("now playing: \(song.isEmpty ? "-" : song)  [\(bundleID ?? "-")]")
        let found = focusPlayer(bundleID: bundleID, pid: now["processIdentifier"] as? Int32, title: song)
        print(found ? "ok    the browser tab with that song was selected"
                   : "note  no browser tab matched, only the app was activated")
    }

    // MARK: layout QA

    // Menu rows are built by menuWillOpen, so a dump has to open them the same way the app does.
    // Returns "" for the top level (the card is a view, not a title) and indents submenus.
    func menuDump() -> String {
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ indent: String) {
            for item in menu.items {
                if item.isSeparatorItem { lines.append(indent + "---"); continue }
                if item.view != nil { lines.append(indent + "(now-playing card)"); continue }
                var line = indent + item.title
                if item.isHidden { line += "   (hidden)" }
                if !item.isEnabled { line += "   (disabled)" }
                lines.append(line)
                if let sub = item.submenu {
                    menuWillOpen(sub)
                    walk(sub, indent + "    ")
                }
            }
        }
        walk(statusMenu, "")
        return lines.isEmpty ? "(no items)\n" : lines.joined(separator: "\n") + "\n"
    }

    // Renders the menu card and the settings window with sample data, light and dark, to PNGs in `dir`,
    // plus the menu structure (menu.txt) with sample history.
    func snapshot(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func render(_ view: NSView, name: String) {
            for dark in [false, true] {
                let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                w.contentView = view
                w.setContentSize(view.frame.size)
                view.layoutSubtreeIfNeeded()
                view.wantsLayer = true
                w.appearance?.performAsCurrentDrawingAppearance {
                    view.layer?.backgroundColor = (name.hasPrefix("card") ? NSColor.underPageBackgroundColor : NSColor.windowBackgroundColor).cgColor
                }
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        let card = makeCard()
        titleLabel.stringValue = "BÊN ÁY EM CÓ AI RỒI - CHÂU KHẢI PHONG | CA SĨ GIẤU MẶT COVER"
        artistLabel.stringValue = "Beta Music"
        artworkView.show(NSImage(contentsOfFile: "tools/icon1024.png"))
        playPauseButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        waveView.setLevels([0.55, 0.9, 0.4, 1.0, 0.65])
        render(card, name: "card-long")
        titleLabel.stringValue = "Not playing"
        artistLabel.stringValue = ""
        artworkView.show(nil)
        playPauseButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        render(card, name: "card-idle")
        buildWindow()
        if let content = window?.contentView { render(content, name: "settings") }

        // status menu structure, with sample history (in a throwaway suite) so the Recently Played rows show up.
        // Built once on purpose: makeStatusMenu() hands its stored items to the menu, so calling it twice throws.
        let scratch = "com.quan.song-notifier.menu-dump"
        let suite = UserDefaults(suiteName: scratch)!
        let flags = "showPopups=\(Flag.showPopups.isOn) showInMenuBar=\(Flag.showInMenuBar.isOn) "
            + "recentList=\(Flag.recentList.isOn)\n"
        History.store = suite
        History.clear()
        statusMenu = makeStatusMenu()
        try? (flags + menuDump()).write(toFile: "\(dir)/menu-empty.txt", atomically: true, encoding: .utf8)
        for _ in 0..<2 {
            History.add(title: "BÊN ÁY EM CÓ AI RỒI - CHÂU KHẢI PHONG | CA SĨ GIẤU MẶT COVER", artist: "Beta Music",
                        url: "https://www.youtube.com/watch?v=example", bundleID: "com.google.Chrome", pid: nil)
        }
        History.add(title: "ĐỔI TÊN", artist: "KAI Hâm Nhạc", url: nil, bundleID: "com.spotify.client", pid: nil)
        // menuDump() opens the submenu the same way AppKit does, so this re-reads the history above
        try? (flags + menuDump()).write(toFile: "\(dir)/menu.txt", atomically: true, encoding: .utf8)
        suite.removePersistentDomain(forName: scratch)
        History.store = UserDefaults.standard
        History.reload()
    }

    func syncLoginBox() {
        let status = SMAppService.mainApp.status
        loginBox?.state = status == .enabled ? .on : .off
        switch status {
        case .requiresApproval:
            loginNote?.stringValue = "Waiting for approval in System Settings → General → Login Items."
        case .notFound:
            loginNote?.stringValue = "Needs the app to live in ~/Applications (run ./build.sh)."
        default:
            loginNote?.stringValue = ""
        }
        let noteShown = !(loginNote?.stringValue.isEmpty ?? true)
        loginNote?.isHidden = !noteShown
        if let login = loginBox { settingsStack?.setCustomSpacing(noteShown ? 2 : 16, after: login) }
        if let w = window, let content = w.contentView { w.setContentSize(content.fittingSize) }
    }

    @objc func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert(error: error)
            a.messageText = "Couldn't change Launch at login"
            a.runModal()
        }
        syncLoginBox()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func toggleMenuBar(_ s: NSButton) {
        Flag.showInMenuBar.set(s.state == .on)
        sizeControl?.isEnabled = s.state == .on
        refreshMenuBar()
    }
    @objc func sizeChanged(_ c: NSSegmentedControl) {
        UserDefaults.standard.set(Controller.sizes[c.selectedSegment].scale, forKey: "menuBarScale")
        scrollOffset = 0
        refreshMenuBar()
    }
    @objc func toggleScroll(_ s: NSButton) { Flag.scrollTitle.set(s.state == .on); scrollOffset = 0; refreshMenuBar() }
    @objc func togglePopups(_ s: NSButton) { setPopups(s.state == .on) }
    @objc func togglePopupsFromMenu() { setPopups(!Flag.showPopups.isOn) }
    @objc func toggleRecent(_ s: NSButton) {
        Flag.recentList.set(s.state == .on)
        refreshMenuBar()  // shows/hides the Recently Played submenu
    }
    @objc func toggleSteering(_ s: NSButton) {
        Flag.steerListening.set(s.state == .on)
    }

    // one place keeps the menu item and the settings checkbox in step; popups off still keeps the menu bar title
    func setPopups(_ on: Bool) {
        Flag.showPopups.set(on)
        popupsMenuItem.state = on ? .on : .off
        popupsBox?.state = on ? .on : .off
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
