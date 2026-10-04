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
        controller.lockForSystem()
        precondition(controller.tiles.isEmpty && controller.password.isEmpty && controller.engine == nil && controller.timer == nil)
        controller.openSettings(); precondition(controller.window.attachedSheet == nil)
        print("PASS: no settings, credentials or playback before authentication; focus layout; stopped-camera preservation; complete relock cleanup.")
        if let monitor = controller.eventMonitor { NSEvent.removeMonitor(monitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(controller)
        controller.window.orderOut(nil)
    }
}
