import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: SettingsStore
    private let readPassword: (String) throws -> String?
    var settings = Settings()
    var password = ""
    var engine: VLCEngine?
    var window: NSWindow!
    let grid = GridView()
    let columns = NSPopUpButton()
    let camerasButton = NSButton(title: "Cameras", target: nil, action: nil)
    let startButton = NSButton(title: "Start", target: nil, action: nil)
    let note = label("Set up your NVR to begin", size: 12)
    var tiles: [UUID: CameraTile] = [:]
    var running = false
    var timer: Timer?
    var editor: SettingsEditor?
    var startupError: Error?
    let gate: AuthenticationGate
    var viewing = ViewingState()
    var hasLoaded = false
    var resumeAfterUnlock: Bool?
    var eventMonitor: Any?

    var hasPlaybackRequests: Bool {
        running && settings.cameras.contains { $0.enabled && $0.streaming }
    }

    override convenience init() {
        self.init(authenticator: LocalDeviceAuthenticator())
    }
    init(authenticator: DeviceAuthenticating, store: SettingsStore = SettingsStore(),
         readPassword: @escaping (String) throws -> String? = PasswordStore.read) {
        self.store = store; self.readPassword = readPassword
        gate = AuthenticationGate(authenticator: authenticator)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HomeGrid"; window.minSize = NSSize(width: 1000, height: 550)
        window.delegate = self; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HomeGrid")
        gate.onChange = { [weak self] in self?.gateChanged() }
        showLockedUI()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.viewing.unlocked, event.window === self.window else { return event }
            if event.type == .keyDown && event.keyCode == 53 && self.viewing.focusedID != nil {
                self.viewing.restoreGrid(); self.rebuildGrid(); return nil
            }
            if event.type == .leftMouseDown && event.clickCount == 2 {
                for tile in self.grid.tiles where !tile.isHidden {
                    let point = tile.convert(event.locationInWindow, from: nil)
                    if tile.bounds.contains(point) && (point.y >= 68 || (point.y < 32 && point.x > 32)) {
                        self.viewing.toggleFocus(tile.camera.id); self.rebuildGrid(); return nil
                    }
                }
            }
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(lockForSystem), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(lockForSystem), name: NSWorkspace.willSleepNotification, object: nil)
        DispatchQueue.main.async { self.gate.unlock() }
    }
    func gateChanged() {
        if gate.state == .unlocked {
            guard !viewing.unlocked else { return }
            viewing.unlocked = true
            openSession()
        } else {
            if viewing.unlocked { closeSession() }
            showLockedUI()
        }
    }
    func showLockedUI() {
        let content = NSView(); window.contentView = content
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = label("HomeGrid is locked", size: 26, bold: true)
        let detail = label(gate.message, size: 14); detail.maximumNumberOfLines = 3
        detail.alignment = .center
        let unlock = NSButton(title: "Unlock with Touch ID or Password", target: self, action: #selector(unlockApp))
        unlock.bezelStyle = .rounded; unlock.isEnabled = gate.state == .locked
        [heading, detail, unlock].forEach(stack.addArrangedSubview)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80)])
    }
    func openSession() {
        startupError = nil
        do {
            if !hasLoaded { settings = try store.load(); hasLoaded = true }
            if !settings.host.isEmpty { password = try readPassword(settings.credentialAccount) ?? "" }
        } catch { startupError = error }
        buildCameraUI()
        running = resumeAfterUnlock ?? (!settings.host.isEmpty && !password.isEmpty)
        resumeAfterUnlock = nil
        viewing.running = running
        rebuildGrid()
        if let error = startupError { showError(error) }
    }
    func closeSession() {
        resumeAfterUnlock = running
        viewing.unlocked = false; running = false; viewing.running = false; viewing.restoreGrid()
        timer?.invalidate(); timer = nil
        editor?.cancel()
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn); sheet.orderOut(nil) }
        editor = nil
        for tile in tiles.values { tile.player?.dispose(); tile.player = nil; tile.removeFromSuperview() }
        tiles.removeAll(); grid.tiles = []; grid.focusedID = nil
        password = ""; engine = nil
    }
    @objc func unlockApp() { gate.unlock() }
    @objc func lockForSystem() { gate.lock() }
    func buildCameraUI() {
        let content = NSView(); window.contentView = content
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 12
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let brand = label("HomeGrid", size: 18, bold: true)
        columns.target = self; columns.action = #selector(changeColumns)
        camerasButton.target = self; camerasButton.action = #selector(showCameras)
        startButton.target = self; startButton.action = #selector(togglePlayback)
        let setup = NSButton(title: "NVR & cameras…", target: self, action: #selector(openSettings))
        let muteAll = NSButton(title: "Mute all", target: self, action: #selector(muteAllCameras))
        let lock = NSButton(title: "Lock", target: self, action: #selector(lockForSystem))
        [camerasButton, startButton, setup, muteAll, lock].forEach { $0.bezelStyle = .rounded }
        columns.removeAllItems()
        columns.addItems(withTitles: (1...3).map { "\($0) column\($0 == 1 ? "" : "s")" })
        columns.selectItem(at: settings.columns - 1)
        [brand, columns, camerasButton, muteAll, startButton, setup, lock, note].forEach(toolbar.addArrangedSubview)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar); content.addSubview(grid)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            grid.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    func buildMenu() {
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let app = NSMenu(); root.submenu = app
        app.addItem(withTitle: "NVR & cameras…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let lock = app.addItem(withTitle: "Lock HomeGrid", action: #selector(lockForSystem), keyEquivalent: "l")
        lock.target = self; lock.keyEquivalentModifierMask = [.command, .shift]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit HomeGrid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    func persist() { guard viewing.unlocked, !settings.host.isEmpty else { return }; do { try store.save(settings) } catch { showError(error) } }
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "HomeGrid"; alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
    func rebuildGrid() {
        guard viewing.unlocked else { return }
        viewing.running = running
        let active = settings.cameras.filter(\.enabled)
        if let focused = viewing.focusedID, !active.contains(where: { $0.id == focused }) { viewing.restoreGrid() }
        if active.contains(where: { viewing.shouldPlay($0) }), engine == nil {
            do { engine = try VLCEngine() } catch { running = false; viewing.running = false; showError(error) }
        }
        let removed = tiles.keys.filter { id in !active.contains { $0.id == id } }
        for id in removed { tiles[id]?.player?.dispose(); tiles[id]?.removeFromSuperview(); tiles.removeValue(forKey: id) }
        for camera in active {
            let tile = tiles[camera.id] ?? CameraTile(camera: camera)
            if tiles[camera.id] == nil { tiles[camera.id] = tile; grid.addSubview(tile) }
            tile.update(camera)
            tile.onQuality = { [weak self, weak tile] quality in
                guard let self, let tile, let index = self.settings.cameras.firstIndex(where: { $0.id == camera.id }) else { return }
                self.settings.cameras[index].quality = quality; self.persist()
                tile.update(self.settings.cameras[index])
                if self.viewing.shouldPlay(tile.camera) { self.play(tile) }
            }
            tile.onMute = { [weak self, weak tile] value in
                guard let self, let tile, let index = self.settings.cameras.firstIndex(where: { $0.id == camera.id }) else { return }
                self.settings.cameras[index].muted = value; self.persist()
                tile.update(self.settings.cameras[index]); tile.player?.setMuted(value)
            }
            tile.onSwap = { [weak self] source, destination in
                guard let self, let a = self.settings.cameras.firstIndex(where: { $0.id == source }),
                      let b = self.settings.cameras.firstIndex(where: { $0.id == destination }) else { return }
                self.settings.cameras.swapAt(a, b); self.persist(); self.rebuildGrid()
            }
            tile.onStreaming = { [weak self] value in
                guard let self, self.viewing.unlocked,
                      let index = self.settings.cameras.firstIndex(where: { $0.id == camera.id }) else { return }
                if value && (self.settings.host.isEmpty || self.password.isEmpty) { self.openSettings(); return }
                self.settings.cameras[index].streaming = value
                if value { self.running = true }
                self.persist(); self.rebuildGrid()
            }
            if viewing.shouldPlay(camera) && !tile.isPlaying { play(tile) }
            if !viewing.shouldPlay(camera) {
                if tile.isPlaying { tile.player?.stop(); tile.isPlaying = false }
                tile.status.stringValue = settings.host.isEmpty ? "Set up NVR" :
                    running && camera.streaming && viewing.focusedID != nil ? "Focus paused" : "Stopped"
            }
        }
        grid.columns = settings.columns; grid.focusedID = viewing.focusedID
        grid.tiles = active.compactMap { tiles[$0.id] }
        camerasButton.title = "Cameras · \(active.count)/6"
        startButton.title = hasPlaybackRequests ? "Stop all" : "Start all"
        note.stringValue = viewing.focusedID != nil ? "Focused camera · Esc restores grid" :
            active.isEmpty ? "No cameras selected" : hasPlaybackRequests ? "Double-click to focus · drag grips to swap" : "Ready · select cameras and start"
        if settings.host.isEmpty { note.stringValue = "Set up your NVR to begin" }
        let hasPlayers = tiles.values.contains(where: { $0.isPlaying })
        if hasPlayers && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.viewing.unlocked else { return }
                self.tiles.values.filter(\.isPlaying).forEach { $0.player?.poll() }
            }
            timer?.tolerance = 0.2
        } else if !hasPlayers { timer?.invalidate(); timer = nil }
    }
    func play(_ tile: CameraTile) {
        guard gate.state == .unlocked, viewing.shouldPlay(tile.camera), let engine else { return }
        do {
            let url = try settings.url(for: tile.camera, password: password)
            if tile.player == nil {
                let player = CameraPlayer(engine: engine, canvas: tile.canvas)
                player.onStatus = { [weak self, weak tile] text in
                    guard let self, self.viewing.unlocked, tile?.isPlaying == true else { return }
                    tile?.status.stringValue = text
                    tile?.status.textColor = text == "Live" ? .systemGreen : .secondaryLabelColor
                }
                tile.player = player
            }
            tile.player?.play(url: url, cacheMS: settings.cacheMS, muted: tile.camera.muted)
            tile.isPlaying = true
        } catch { showError(error) }
    }
    @objc func changeColumns() { guard viewing.unlocked else { return }; settings.columns = columns.indexOfSelectedItem + 1; persist(); rebuildGrid() }
    @objc func showCameras() {
        guard viewing.unlocked else { return }
        let menu = NSMenu()
        for camera in settings.cameras {
            let item = NSMenuItem(title: "\(camera.name) · channel \(camera.channel)", action: #selector(toggleCamera(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = camera.id.uuidString; item.state = camera.enabled ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: camerasButton.bounds.height), in: camerasButton)
    }
    @objc func toggleCamera(_ item: NSMenuItem) {
        guard viewing.unlocked else { return }
        guard let raw = item.representedObject as? String, let index = settings.cameras.firstIndex(where: { $0.id.uuidString == raw }) else { return }
        settings.cameras[index].enabled.toggle(); persist(); rebuildGrid()
    }
    @objc func muteAllCameras() {
        guard viewing.unlocked else { return }
        for index in settings.cameras.indices { settings.cameras[index].muted = true }
        tiles.values.forEach { tile in
            if let camera = settings.cameras.first(where: { $0.id == tile.camera.id }) { tile.update(camera); tile.player?.setMuted(true) }
        }
        persist()
    }
    @objc func togglePlayback() {
        guard viewing.unlocked else { return }
        let shouldStart = !hasPlaybackRequests
        if shouldStart && (settings.host.isEmpty || password.isEmpty) { openSettings(); return }
        running = shouldStart
        // A global stop must update the per-camera state too: starting one tile
        // then resumes only that camera, rather than the old global session.
        for index in settings.cameras.indices { settings.cameras[index].streaming = running }
        persist(); rebuildGrid()
    }
    @objc func openSettings() {
        guard viewing.unlocked else { return }
        editor = SettingsEditor(settings: settings)
        editor?.onSave = { [weak self] updated, entered in
            guard let self, self.viewing.unlocked else { return }
            let secret = try entered ?? PasswordStore.read(updated.credentialAccount)
            guard let secret, !secret.isEmpty else { throw GridError.message("Enter the password for this NVR account.") }
            if entered != nil { try PasswordStore.save(secret, account: updated.credentialAccount) }
            try self.store.save(updated)
            self.settings = updated; self.password = secret
            self.tiles.values.forEach { $0.player?.stop(); $0.isPlaying = false }
            self.running = true; self.rebuildGrid()
        }
        editor?.show(on: window)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        gate.onChange = nil; gate.lock()
        let group = DispatchGroup()
        for tile in tiles.values {
            guard let player = tile.player else { continue }
            group.enter(); player.dispose { group.leave() }
        }
        group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
