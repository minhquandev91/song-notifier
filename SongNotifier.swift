import AppKit
import ServiceManagement
import UserNotifications

// Shows a macOS notification whenever the "Now Playing" song changes (browsers, Apple Music, Spotify),
// optionally with the song rolling through the menu bar. Clicking a popup focuses the player.

// A second copy (e.g. started by hand) would double every popup; the running one wins.
if let id = Bundle.main.bundleIdentifier,
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

    var isPlaying: Bool { (state["playing"] as? Bool) == true }
    var songLine: String {
        guard let title = state["title"] as? String, !title.isEmpty else { return "" }
        let artist = state["artist"] as? String ?? ""
        return artist.isEmpty ? title : "\(title) — \(artist)"
    }

    func applicationDidFinishLaunching(_ n: Notification) {
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

    // Now-playing card at the top of the menu: artwork on the left; title, artist and the ⏮ ⏯ ⏭ icon
    // buttons stacked on the right. Clicking a button doesn't close the menu, so the play/pause icon
    // can be seen flipping. Menu item views get a fixed frame, hence the fixed sizes.
    func makeCard() -> NSView {
        let textWidth: CGFloat = 220, art: CGFloat = 96, pad: CGFloat = 16

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            b.contentTintColor = .labelColor
            b.toolTip = tip
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return b
        }
        let playPause = button("play.fill", "Play / Pause", #selector(togglePlayPause))
        playPauseButton = playPause
        let controls = NSStackView(views: [button("backward.fill", "Previous", #selector(previousTrack)),
                                           playPause,
                                           button("forward.fill", "Next", #selector(nextTrack))])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fillEqually

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [titleLabel, artistLabel, controls])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.setCustomSpacing(8, after: artistLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        for v in [titleLabel, artistLabel, controls] { v.widthAnchor.constraint(equalToConstant: textWidth).isActive = true }
        titleLabel.heightAnchor.constraint(equalToConstant: 38).isActive = true  // room for two lines, top-aligned

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        let height = art + 2 * pad
        let container = NSView(frame: NSRect(x: 0, y: 0, width: pad + art + 14 + textWidth + pad, height: height))
        container.addSubview(artworkView)
        container.addSubview(column)
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            artworkView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: art),
            artworkView.heightAnchor.constraint(equalToConstant: art),
            column.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 14),
            column.centerYAnchor.constraint(equalTo: container.centerYAnchor),
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
        stack.setCustomSpacing(2, after: login)
        stack.setCustomSpacing(16, after: hint)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        hint.preferredMaxLayoutWidth = 320
        note.preferredMaxLayoutWidth = 320

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Song Notifier"
        w.contentView = stack
        w.isReleasedWhenClosed = false
        w.setContentSize(stack.fittingSize)
        w.center()
        window = w
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
