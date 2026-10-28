import AppKit
import ServiceManagement
import UserNotifications

// Shows a macOS notification whenever the "Now Playing" song changes (browsers, Apple Music, Spotify),
// optionally with the song rolling through the menu bar. Clicking a popup focuses the player.

// A second copy (e.g. started by hand) would double every popup; the running one wins.
let snapshotMode = CommandLine.arguments.contains("--snapshot")
if !snapshotMode, let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

// MARK: - Settings (UserDefaults; every flag defaults to on)

enum Flag: String {
    case showPopups, showInMenuBar, scrollTitle
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

    func show(_ image: NSImage?) {
        let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contents = cg
        placeholder.isHidden = cg != nil
    }
}

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

final class Controller: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
    var playPauseButton: NSButton?
    let artworkView = ArtworkView(frame: .zero)
    let waveView = WaveView(frame: .zero)
    let titleLabel = NSTextField(wrappingLabelWithString: "Not playing")
    let artistLabel = NSTextField(labelWithString: "")
    let popupsMenuItem = NSMenuItem(title: "Show popups", action: #selector(togglePopupsFromMenu), keyEquivalent: "")
    let menuBarChars = 28  // fixed width in a monospaced font so the rolling text doesn't jiggle the bar
    var scrollOffset = 0
    var ticker: Timer?

    // settings window
    var window: NSWindow?
    var loginBox: NSButton?
    var loginNote: NSTextField?
    var popupsBox: NSButton?
    var settingsStack: NSStackView?

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
        un.delegate = self
        un.requestAuthorization(options: [.alert]) { granted, err in
            print("notification permission granted:", granted, err?.localizedDescription ?? "")
        }

        let menu = NSMenu()
        let card = NSMenuItem()
        card.view = makeCard()
        menu.addItem(card)
        menu.addItem(.separator())
        popupsMenuItem.target = self
        popupsMenuItem.state = Flag.showPopups.isOn ? .on : .off
        menu.addItem(popupsMenuItem)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Song Notifier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/media-control")
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
            guard Flag.showPopups.isOn else { return }
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

    // MARK: music controls (media-control talks to whatever app owns Now Playing)

    func control(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/media-control")
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

    @objc func previousTrack() { control("previous-track") }
    @objc func nextTrack() { control("next-track") }
    @objc func togglePlayPause() { control("toggle-play-pause") }

    // MARK: menu bar

    func refreshMenuBar() {
        statusItem.isVisible = Flag.showInMenuBar.isOn
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
        menubar.state = Flag.showInMenuBar.isOn ? .on : .off
        scroll.state = Flag.scrollTitle.isOn ? .on : .off
        popups.state = Flag.showPopups.isOn ? .on : .off
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

        let stack = NSStackView(views: [login, note, menubar, scroll, popups, hint, copyright])
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

    // MARK: layout QA

    // Renders the menu card and the settings window with sample data, light and dark, to PNGs in `dir`.
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
    @objc func toggleMenuBar(_ s: NSButton) { Flag.showInMenuBar.set(s.state == .on); refreshMenuBar() }
    @objc func toggleScroll(_ s: NSButton) { Flag.scrollTitle.set(s.state == .on); scrollOffset = 0; refreshMenuBar() }
    @objc func togglePopups(_ s: NSButton) { setPopups(s.state == .on) }
    @objc func togglePopupsFromMenu() { setPopups(!Flag.showPopups.isOn) }

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
