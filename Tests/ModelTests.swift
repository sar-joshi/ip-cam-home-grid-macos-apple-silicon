import Foundation

@main struct ModelTests {
    static func main() throws {
        var settings = Settings(); settings.host = "127.0.0.1"; settings.username = "viewer:name"
        let secret = "p@ss:#?/&% word"
        for quality in StreamQuality.allCases {
            var camera = settings.cameras[0]; camera.quality = quality
            let url = try settings.url(for: camera, password: secret)
            let parts = URLComponents(string: url)!
            precondition(parts.user == settings.username && parts.password == secret)
            precondition(parts.queryItems == [URLQueryItem(name: "channel", value: "1"), URLQueryItem(name: "subtype", value: String(quality.rawValue))])
            precondition(parts.host == "127.0.0.1" && parts.port == 554)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HomeGrid-tests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SettingsStore(file: file)
        settings.cameras.swapAt(0, 5); settings.cameras[1].enabled = false
        settings.cameras[2].muted = false; settings.cameras[3].quality = .low
        settings.columns = 2
        try store.save(settings)
        let loaded = try store.load()
        precondition(loaded.cameras == settings.cameras && loaded.columns == 2)
        let data = try String(contentsOf: file, encoding: .utf8)
        precondition(!data.contains(secret) && !data.contains("password"))
        settings.cameras[2].streaming = false
        try store.save(settings)
        let stoppedSettings = try store.load()
        precondition(stoppedSettings.cameras[2].streaming == false)
        // Old settings migrate without resetting names, order or stream quality.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        old["cameras"] = (old["cameras"] as! [[String: Any]]).map { camera in
            var camera = camera; camera.removeValue(forKey: "streaming"); return camera
        }
        let migrated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(migrated.cameras.allSatisfy(\.streaming))
        precondition(migrated.cameras.map(\.id) == settings.cameras.map(\.id))
        var view = ViewingState()
        precondition(!settings.cameras.contains(where: { view.shouldPlay($0) }))
        view.unlocked = true; view.running = true
        precondition(settings.cameras.filter { view.shouldPlay($0) }.count == 4)
        let focus = settings.cameras[0].id
        view.toggleFocus(focus)
        precondition(settings.cameras.filter { view.shouldPlay($0) }.map(\.id) == [focus])
        view.toggleFocus(focus)
        precondition(view.focusedID == nil)
        view.toggleFocus(focus); view.restoreGrid()
        precondition(settings.cameras.filter { view.shouldPlay($0) }.count == 4)
        view.running = false
        precondition(!settings.cameras.contains(where: { view.shouldPlay($0) }))
        view.running = true; view.unlocked = false
        precondition(!settings.cameras.contains(where: { view.shouldPlay($0) }))
        for invalid in ["rtsp://192.168.1.1", "camera/path", "user@camera", ""] {
            var bad = settings; bad.host = invalid
            do { try bad.validate(); fatalError("Accepted an invalid host") } catch {}
        }
        var bad = settings; bad.cameras[0].channel = 0
        do { try bad.validate(); fatalError("Accepted channel zero") } catch {}
        print("PASS: URLs, settings migration, saved per-camera stop, focus/restore playback plan, locked playback exclusion and input validation.")
    }
}
