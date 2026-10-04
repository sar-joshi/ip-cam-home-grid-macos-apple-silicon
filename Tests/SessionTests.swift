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
        try store.save(settings)
        let device = SessionAuthenticator()
        var credentialReads = 0
        let controller = AppController(authenticator: device, store: store, readPassword: { _ in
            credentialReads += 1; return nil // Never read the real Keychain or start network playback.
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
        controller.running = true
        controller.togglePlayback() // Stop all records each camera as stopped.
        precondition(controller.settings.cameras.allSatisfy { !$0.streaming })
        // Keep the fixture hidden so this controller test allocates no decoder
        // and never connects to a network or reads the real Keychain.
        for index in controller.settings.cameras.indices { controller.settings.cameras[index].enabled = false }
        controller.password = "synthetic-test-only"
        tile.onStreaming?(true)
        precondition(controller.running)
        precondition(controller.settings.cameras.filter(\.streaming).map(\.id) == [camera.id])
        let persisted = try store.load()
        precondition(persisted.cameras.filter(\.streaming).map(\.id) == [camera.id])
        var visible = controller.settings.cameras
        for index in visible.indices { visible[index].enabled = true }
        precondition(visible.filter { controller.viewing.shouldPlay($0) }.map(\.id) == [camera.id])
        controller.togglePlayback() // Stop all, then explicit Start all.
        controller.togglePlayback()
        precondition(controller.settings.cameras.allSatisfy(\.streaming))
        controller.togglePlayback()
        precondition(controller.engine == nil && controller.timer == nil)
        controller.lockForSystem()
        precondition(controller.tiles.isEmpty && controller.password.isEmpty && controller.engine == nil && controller.timer == nil)
        controller.openSettings(); precondition(controller.window.attachedSheet == nil)
        print("PASS: authentication gate; focus; Stop all then individual Start; explicit Start all; persisted stop choices; complete relock cleanup.")
        if let monitor = controller.eventMonitor { NSEvent.removeMonitor(monitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(controller)
        controller.window.orderOut(nil)
    }
}
