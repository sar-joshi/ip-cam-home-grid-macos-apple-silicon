import Foundation
import Security

enum StreamQuality: Int, Codable, CaseIterable {
    case main = 0, balanced = 1, low = 2
    var title: String { ["Main · 0", "Sub 1 · 1", "Sub 2 · 2"][rawValue] }
}

struct Camera: Codable, Equatable {
    var id = UUID()
    var name: String
    var channel: Int
    var enabled = true
    var quality: StreamQuality = .balanced
    var muted = true
    var streaming = true

    init(name: String, channel: Int) { self.name = name; self.channel = channel }

    private enum CodingKeys: String, CodingKey { case id, name, channel, enabled, quality, muted, streaming }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        channel = try values.decode(Int.self, forKey: .channel)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        quality = try values.decode(StreamQuality.self, forKey: .quality)
        muted = try values.decode(Bool.self, forKey: .muted)
        // Preferences saved by version 0.1 did not have a per-camera stop state.
        streaming = try values.decodeIfPresent(Bool.self, forKey: .streaming) ?? true
    }
}

struct ViewingState {
    var unlocked = false
    var running = false
    var focusedID: UUID?
    mutating func toggleFocus(_ id: UUID) { focusedID = focusedID == id ? nil : id }
    mutating func restoreGrid() { focusedID = nil }
    func shouldPlay(_ camera: Camera) -> Bool {
        unlocked && running && camera.enabled && camera.streaming && (focusedID == nil || focusedID == camera.id)
    }
}

struct Settings: Codable {
    var host = ""
    var port = 554
    var username = ""
    var columns = 3
    var cacheMS = 350
    var cameras = (1...6).map { Camera(name: "Camera \($0)", channel: $0) }
    var credentialAccount: String { "\(username)@\(host.lowercased()):\(port)" }

    func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains), !host.contains("..") else {
            throw GridError.message("Enter an NVR IP address or hostname, without a URL, port or path.")
        }
        guard (1...65535).contains(port), (100...3000).contains(cacheMS), (1...3).contains(columns),
              !username.isEmpty, cameras.count == 6,
              cameras.allSatisfy({ (1...256).contains($0.channel) && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }),
              Set(cameras.map(\.id)).count == cameras.count else {
            throw GridError.message("Check the port, username, camera names and channel numbers. Cache must be 100–3000 ms.")
        }
    }

    func url(for camera: Camera, password: String) throws -> String {
        try validate()
        var parts = URLComponents()
        parts.scheme = "rtsp"
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = port
        // Escape delimiters explicitly: URLComponents otherwise permits ':' in user info.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        parts.percentEncodedUser = username.addingPercentEncoding(withAllowedCharacters: safe)
        parts.percentEncodedPassword = password.addingPercentEncoding(withAllowedCharacters: safe)
        parts.path = "/cam/realmonitor"
        parts.queryItems = [URLQueryItem(name: "channel", value: String(camera.channel)),
                            URLQueryItem(name: "subtype", value: String(camera.quality.rawValue))]
        guard let url = parts.url else { throw GridError.message("Could not construct the RTSP address.") }
        return url.absoluteString
    }
}

enum GridError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

final class SettingsStore {
    let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeGrid/settings.json")
    }
    func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: file.path) else { return Settings() }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        try settings.validate()
        return settings
    }
    func save(_ settings: Settings) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum PasswordStore {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.homegrid.nvr",
         kSecAttrAccount as String: account]
    }
    static func read(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw GridError.message("Could not read the NVR password from Keychain (\(status)).")
        }
        return password
    }
    static func save(_ password: String, account: String) throws {
        let q = query(account)
        let values = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = q.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GridError.message("Could not save the password to Keychain (\(status)). Settings were not applied.") }
    }
}
