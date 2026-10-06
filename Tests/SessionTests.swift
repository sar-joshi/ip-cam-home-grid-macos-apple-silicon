import AppKit

final class SessionAuthenticator: DeviceAuthenticating {
    var reply: ((Bool, String?) -> Void)?
    func authenticate(completion: @escaping (Bool, String?) -> Void) { reply = completion }
    func cancel() {}
}

@main struct SessionTests {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HomeGrid-session-\(UUID()).json")
        let store = SettingsStore(file: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = Settings(); settings.host = "127.0.0.1"; settings.username = "synthetic"
        for index in settings.cameras.indices { settings.cameras[index].streaming = false }
        try store.save(settings)
        let device = SessionAuthenticator()
        var credentialReads = 0
        var savedPassword: String? = "synthetic-test-only"
        let controller = AppController(authenticator: device, store: store, readPassword: { _ in
            credentialReads += 1; return savedPassword // Never read the real Keychain.
        })
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        controller.openSettings(); controller.togglePlayback(); controller.muteAllCameras()
        precondition(controller.tiles.isEmpty && controller.engine == nil && credentialReads == 0)
        precondition(controller.window.attachedSheet == nil)
        controller.gate.unlock(); device.reply?(false, "Denied")
        precondition(controller.tiles.isEmpty && credentialReads == 0)
        controller.gate.unlock(); device.reply?(true, nil)
        precondition(controller.tiles.count == 6 && credentialReads == 1)
        precondition(controller.engine == nil && controller.timer == nil) // No idle media engine or polling.
        precondition(controller.running && controller.settings.cameras.allSatisfy { !$0.streaming })
        precondition(controller.startButton.title == "Start all") // Saved stops override the ready session flag.
        let camera = controller.settings.cameras[0]
        let tile = controller.tiles[camera.id]!
        tile.onStreaming?(false)
        precondition(!controller.settings.cameras[0].streaming)
        controller.viewing.toggleFocus(camera.id); controller.rebuildGrid()
        controller.window.contentView?.layoutSubtreeIfNeeded()
        precondition(controller.grid.tiles.filter { !$0.isHidden }.map { $0.camera.id } == [camera.id])
        controller.viewing.restoreGrid(); controller.rebuildGrid()
        controller.window.contentView?.layoutSubtreeIfNeeded()
        precondition(controller.grid.tiles.filter { !$0.isHidden }.count == 6)
        precondition(!controller.settings.cameras[0].streaming) // Focus never resumes an explicitly stopped camera.
        // Test the first Start all click with a ready session and saved stops.
        // Hide this synthetic fixture to avoid any media or network allocation.
        for index in controller.settings.cameras.indices { controller.settings.cameras[index].enabled = false }
        controller.togglePlayback()
        precondition(controller.running && controller.settings.cameras.allSatisfy(\.streaming))
        // Restore selection, then stop its requests before the next rebuild.
        for index in controller.settings.cameras.indices { controller.settings.cameras[index].enabled = true }
        precondition(controller.hasPlaybackRequests)
        controller.togglePlayback() // Stop all records each camera as stopped.
        precondition(controller.settings.cameras.allSatisfy { !$0.streaming })
        precondition(controller.startButton.title == "Start all")
        // Keep the fixture hidden so this controller test allocates no decoder
        // and never connects to a network or reads the real Keychain.
        for index in controller.settings.cameras.indices { controller.settings.cameras[index].enabled = false }
        controller.password = "synthetic-test-only"
        tile.onStreaming?(true)
        precondition(controller.running)
        precondition(!controller.hasPlaybackRequests) // No selected cameras request playback.
        precondition(controller.settings.cameras.filter(\.streaming).map(\.id) == [camera.id])
        let persisted = try store.load()
        precondition(persisted.cameras.filter(\.streaming).map(\.id) == [camera.id])
        var visible = controller.settings.cameras
        for index in visible.indices { visible[index].enabled = true }
        precondition(visible.filter { controller.viewing.shouldPlay($0) }.map(\.id) == [camera.id])
        controller.settings.cameras[0].enabled = true
        precondition(controller.hasPlaybackRequests)
        tile.onStreaming?(false) // Individually stopping the last selected camera updates the global button.
        precondition(controller.running && !controller.hasPlaybackRequests)
        precondition(controller.startButton.title == "Start all")
        controller.settings.cameras[0].enabled = false
        tile.onStreaming?(true)
        controller.settings.cameras[0].enabled = true
        controller.viewing.toggleFocus(controller.settings.cameras[1].id)
        precondition(controller.hasPlaybackRequests) // Focus does not change the global request scope.
        controller.togglePlayback() // Stop the selected request before allocating a player.
        precondition(controller.startButton.title == "Start all")
        controller.settings.cameras[0].enabled = false
        controller.togglePlayback()
        precondition(controller.settings.cameras.allSatisfy(\.streaming))
        precondition(controller.startButton.title == "Start all") // Hidden cameras are not playing.
        controller.settings.cameras[0].enabled = true
        controller.togglePlayback()
        precondition(controller.engine == nil && controller.timer == nil)
        precondition(controller.startButton.title == "Start all")
        controller.lockForSystem()
        precondition(controller.tiles.isEmpty && controller.password.isEmpty && controller.engine == nil && controller.timer == nil)
        controller.openSettings(); precondition(controller.window.attachedSheet == nil)
        savedPassword = nil
        controller.gate.unlock(); device.reply?(true, nil)
        precondition(credentialReads == 2 && !controller.running && controller.startButton.title == "Start all")
        precondition(controller.engine == nil && controller.timer == nil)
        controller.togglePlayback()
        precondition(controller.window.attachedSheet != nil && !controller.running) // Missing credentials open setup.
        controller.lockForSystem()
        precondition(controller.window.attachedSheet == nil && controller.tiles.isEmpty && controller.password.isEmpty)
        print("PASS: authentication gate; saved-stop startup and first Start all; last-camera stop; selection/focus scope; individual/global Start; persisted stops; missing-credential setup; relock cleanup.")
        if let monitor = controller.eventMonitor { NSEvent.removeMonitor(monitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(controller)
        controller.window.orderOut(nil)
    }
}
