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
    case showPopups, showInMenuBar, scrollTitle, recentList
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
    return selectedTab
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

// Newest first, de-duplicated by title+artist: hearing a song again moves it back to the top and counts a play.
// Bounded so the store never grows (25 kept, 10 shown); no artwork — thumbnails would bloat UserDefaults.
enum History {
    static let kept = 25, shown = 10
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
        check(tracks.count == kept, "capped at \(kept) rows")
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

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let un = UNUserNotificationCenter.current()

    // Now Playing state is fed by `media-control stream` (brew install ungive/media-control/media-control),
    // which reports whatever macOS considers "now playing": browsers, Apple Music, Spotify, ...
    var state: [String: Any] = [:]
    var lastTrack = ""
    var pending: DispatchWorkItem?
    var helper: Process?
    var buffer = Data()

    // menu bar
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var statusMenu = NSMenu()
    var playPauseButton: NSButton?
    let artworkView = ArtworkView(frame: .zero)
    let waveView = WaveView(frame: .zero)
    let titleLabel = NSTextField(wrappingLabelWithString: "Not playing")
    let artistLabel = NSTextField(labelWithString: "")
    let popupsMenuItem = NSMenuItem(title: "Show popups", action: #selector(togglePopupsFromMenu), keyEquivalent: "")
    // Recently Played: the rows are rebuilt in menuWillOpen, so the menu never changes while it is closed.
    let recentMenuItem = NSMenuItem(title: "Recently Played", action: nil, keyEquivalent: "")
    let recentMenu = NSMenu()
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

    // settings window
    var window: NSWindow?
    var loginBox: NSButton?
    var loginNote: NSTextField?
    var popupsBox: NSButton?
    var settingsStack: NSStackView?
    var sizeControl: NSSegmentedControl?

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

        statusMenu = makeStatusMenu()
        statusItem.menu = statusMenu
        statusItem.button?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.scrollOffset += 1
            self?.refreshMenuBar()
        }
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
            let artist = state["artist"] as? String ?? ""
            let album = state["album"] as? String ?? ""
            let bundleID = state["bundleIdentifier"] as? String
            let pid = state["processIdentifier"] as? Int32
            // the history is not a notification, so it is recorded even with popups switched off.
            // The link is read here, while that song is still the one in the tab.
            if Flag.recentList.isOn {
                History.add(title: name, artist: artist, url: playingURL(bundleID: bundleID, title: name),
                            bundleID: bundleID, pid: pid)
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
        for v in [artworkView, titleLabel, artistLabel, controls] { container.addSubview(v) }
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

            // the first glyph sits ~3pt inside its button; shift the row left so the glyph lines up with the text
            controls.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -3),
            controls.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 2),
        ])
        return container
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
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Song Notifier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    // Rebuilt on every open: the rows always match History, without touching the menu while it is closed.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
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
    }

    // Clicking a row goes back to that song: the tab is selected if it is still open, otherwise the link
    // stored with the row is opened in the player's browser. Returns true when the song was reached.
    @discardableResult
    @objc func openRecent(_ item: NSMenuItem) -> Bool {
        guard let t = item.representedObject as? Track else { return false }
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
        menubar.state = Flag.showInMenuBar.isOn ? .on : .off
        scroll.state = Flag.scrollTitle.isOn ? .on : .off
        popups.state = Flag.showPopups.isOn ? .on : .off
        recent.state = Flag.recentList.isOn ? .on : .off
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

        let stack = NSStackView(views: [login, note, menubar, scroll, widthRow, popups, recent, hint, copyright])
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

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Song Notifier"
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
