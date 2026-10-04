import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = SettingsStore()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do { settings = try store.load(); password = try PasswordStore.read(settings.credentialAccount) ?? "" }
        catch { startupError = error }
        do { engine = try VLCEngine() } catch { startupError = error }
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HomeGrid"; window.minSize = NSSize(width: 1000, height: 550)
        window.delegate = self; window.isReleasedWhenClosed = false
        let content = NSView(); window.contentView = content
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 12
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let brand = label("HomeGrid", size: 18, bold: true)
        columns.addItems(withTitles: (1...3).map { "\($0) column\($0 == 1 ? "" : "s")" })
        columns.selectItem(at: settings.columns - 1); columns.target = self; columns.action = #selector(changeColumns)
        camerasButton.target = self; camerasButton.action = #selector(showCameras)
        startButton.target = self; startButton.action = #selector(togglePlayback)
        let setup = NSButton(title: "NVR & cameras…", target: self, action: #selector(openSettings))
        let muteAll = NSButton(title: "Mute all", target: self, action: #selector(muteAllCameras))
        [camerasButton, startButton, setup, muteAll].forEach { $0.bezelStyle = .rounded }
        [brand, columns, camerasButton, muteAll, startButton, setup, note].forEach(toolbar.addArrangedSubview)
        note.textColor = .secondaryLabelColor
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
        rebuildGrid()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tiles.values.forEach { $0.player?.poll() }
        }
        if let error = startupError { showError(error) }
        else if !settings.host.isEmpty, !password.isEmpty { running = true; rebuildGrid() }
    }
    func buildMenu() {
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let app = NSMenu(); root.submenu = app
        app.addItem(withTitle: "NVR & cameras…", action: #selector(openSettings), keyEquivalent: ",").target = self
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
    func persist() { guard !settings.host.isEmpty else { return }; do { try store.save(settings) } catch { showError(error) } }
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "HomeGrid"; alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
    func rebuildGrid() {
        let active = settings.cameras.filter(\.enabled)
        let removed = tiles.keys.filter { id in !active.contains { $0.id == id } }
        for id in removed { tiles[id]?.player?.dispose(); tiles[id]?.removeFromSuperview(); tiles.removeValue(forKey: id) }
        for camera in active {
            let tile = tiles[camera.id] ?? CameraTile(camera: camera)
            if tiles[camera.id] == nil { tiles[camera.id] = tile; grid.addSubview(tile) }
            tile.update(camera)
            tile.onQuality = { [weak self, weak tile] quality in
                guard let self, let tile, let index = self.settings.cameras.firstIndex(where: { $0.id == camera.id }) else { return }
                self.settings.cameras[index].quality = quality; self.persist()
                tile.update(self.settings.cameras[index]); self.play(tile)
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
            if running && !tile.isPlaying { play(tile) }
            if !running {
                if tile.isPlaying { tile.player?.stop(); tile.isPlaying = false }
                tile.status.stringValue = settings.host.isEmpty ? "Set up NVR" : "Stopped"
            }
        }
        grid.columns = settings.columns; grid.tiles = active.compactMap { tiles[$0.id] }
        camerasButton.title = "Cameras · \(active.count)/6"
        startButton.title = running ? "Stop" : "Start"
        note.stringValue = active.isEmpty ? "No cameras selected" : running ? "RTSP over TCP · drag grips to swap" : "Ready · select cameras and start"
        if settings.host.isEmpty { note.stringValue = "Set up your NVR to begin" }
    }
    func play(_ tile: CameraTile) {
        guard running, let engine else { return }
        do {
            let url = try settings.url(for: tile.camera, password: password)
            if tile.player == nil {
                let player = CameraPlayer(engine: engine, canvas: tile.canvas)
                player.onStatus = { [weak tile] text in
                    tile?.status.stringValue = text
                    tile?.status.textColor = text == "Live" ? .systemGreen : .secondaryLabelColor
                }
                tile.player = player
            }
            tile.player?.play(url: url, cacheMS: settings.cacheMS, muted: tile.camera.muted)
            tile.isPlaying = true
        } catch { showError(error) }
    }
    @objc func changeColumns() { settings.columns = columns.indexOfSelectedItem + 1; persist(); rebuildGrid() }
    @objc func showCameras() {
        let menu = NSMenu()
        for camera in settings.cameras {
            let item = NSMenuItem(title: "\(camera.name) · channel \(camera.channel)", action: #selector(toggleCamera(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = camera.id.uuidString; item.state = camera.enabled ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: camerasButton.bounds.height), in: camerasButton)
    }
    @objc func toggleCamera(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let index = settings.cameras.firstIndex(where: { $0.id.uuidString == raw }) else { return }
        settings.cameras[index].enabled.toggle(); persist(); rebuildGrid()
    }
    @objc func muteAllCameras() {
        for index in settings.cameras.indices { settings.cameras[index].muted = true }
        tiles.values.forEach { tile in
            if let camera = settings.cameras.first(where: { $0.id == tile.camera.id }) { tile.update(camera); tile.player?.setMuted(true) }
        }
        persist()
    }
    @objc func togglePlayback() {
        if !running && (settings.host.isEmpty || password.isEmpty) { openSettings(); return }
        guard engine != nil else { showError(GridError.message("VLC is unavailable. Reinstall VLC and restart HomeGrid.")); return }
        running.toggle(); rebuildGrid()
    }
    @objc func openSettings() {
        editor = SettingsEditor(settings: settings)
        editor?.onSave = { [weak self] updated, entered in
            guard let self else { return }
            let secret = try entered ?? PasswordStore.read(updated.credentialAccount)
            guard let secret, !secret.isEmpty else { throw GridError.message("Enter the password for this NVR account.") }
            if entered != nil { try PasswordStore.save(secret, account: updated.credentialAccount) }
            try self.store.save(updated)
            self.settings = updated; self.password = secret
            self.tiles.values.forEach { $0.isPlaying = false }
            self.running = self.engine != nil; self.rebuildGrid()
        }
        editor?.show(on: window)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        let group = DispatchGroup()
        for tile in tiles.values {
            guard let player = tile.player else { continue }
            group.enter(); player.dispose { group.leave() }
        }
        group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
