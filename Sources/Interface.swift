import AppKit

let cameraDragType = NSPasteboard.PasteboardType("local.homegrid.camera")

func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
    return field
}

final class DragHandle: NSView, NSDraggingSource {
    var cameraID = UUID()
    override func draw(_ dirtyRect: NSRect) {
        ("⠿" as NSString).draw(in: bounds.insetBy(dx: 5, dy: 5), withAttributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 19)])
    }
    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem(); item.setString(cameraID.uuidString, forType: cameraDragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: NSSize(width: 100, height: 50))
        image.lockFocus(); NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 100, height: 50), xRadius: 8, yRadius: 8).fill()
        image.unlockFocus()
        dragging.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: image.size), contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

final class CameraTile: NSView {
    override var isFlipped: Bool { true }
    let canvas = NSView()
    let title = label("", bold: true)
    let status = label("Stopped", size: 11)
    let quality = NSPopUpButton()
    let mute = NSButton()
    let streamButton = NSButton()
    let handle = DragHandle()
    var camera: Camera
    var player: CameraPlayer?
    var isPlaying = false { didSet { streamButton.title = isPlaying ? "Stop" : "Start" } }
    var onQuality: ((StreamQuality) -> Void)?
    var onMute: ((Bool) -> Void)?
    var onSwap: ((UUID, UUID) -> Void)?
    var onStreaming: ((Bool) -> Void)?
    var dropHighlight = false

    init(camera: Camera) {
        self.camera = camera
        super.init(frame: .zero)
        quality.addItems(withTitles: StreamQuality.allCases.map(\.title))
        quality.target = self; quality.action = #selector(changeQuality)
        quality.font = .systemFont(ofSize: 11)
        mute.bezelStyle = .rounded; mute.target = self; mute.action = #selector(toggleMute)
        mute.font = .systemFont(ofSize: 11)
        streamButton.bezelStyle = .rounded; streamButton.font = .systemFont(ofSize: 11)
        streamButton.target = self; streamButton.action = #selector(toggleStreaming)
        status.textColor = .secondaryLabelColor
        canvas.autoresizesSubviews = true
        [canvas, title, status, quality, mute, streamButton, handle].forEach(addSubview)
        registerForDraggedTypes([cameraDragType])
        update(camera)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 68).fill()
        if dropHighlight {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); path.lineWidth = 4; path.stroke()
        }
    }
    override func layout() {
        super.layout()
        handle.frame = NSRect(x: 6, y: 4, width: 25, height: 28)
        title.frame = NSRect(x: 36, y: 8, width: max(40, bounds.width - 210), height: 18)
        title.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: bounds.width - 165, y: 10, width: 155, height: 15)
        status.alignment = .right
        quality.frame = NSRect(x: 36, y: 35, width: 119, height: 26)
        mute.frame = NSRect(x: 161, y: 35, width: 68, height: 26)
        streamButton.frame = NSRect(x: 235, y: 35, width: 68, height: 26)
        canvas.frame = NSRect(x: 0, y: 68, width: bounds.width, height: max(0, bounds.height - 68))
    }
    func update(_ camera: Camera) {
        self.camera = camera; handle.cameraID = camera.id
        title.stringValue = camera.name
        title.toolTip = "NVR channel \(camera.channel). Drag the grip to another camera to swap positions."
        quality.selectItem(at: camera.quality.rawValue)
        mute.title = camera.muted ? "Unmute" : "Mute"
        streamButton.title = isPlaying ? "Stop" : "Start"
    }
    @objc private func changeQuality() { if let q = StreamQuality(rawValue: quality.indexOfSelectedItem) { onQuality?(q) } }
    @objc private func toggleMute() { onMute?(!camera.muted) }
    @objc private func toggleStreaming() { onStreaming?(!isPlaying) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let raw = sender.draggingPasteboard.string(forType: cameraDragType), let id = UUID(uuidString: raw), id != camera.id else { return [] }
        dropHighlight = true; needsDisplay = true; return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false; needsDisplay = true
        guard let raw = sender.draggingPasteboard.string(forType: cameraDragType), let id = UUID(uuidString: raw), id != camera.id else { return false }
        onSwap?(id, camera.id); return true
    }
}

final class GridView: NSView {
    override var isFlipped: Bool { true }
    var columns = 3 { didSet { needsLayout = true } }
    var tiles: [CameraTile] = [] { didSet { needsLayout = true } }
    var focusedID: UUID? { didSet { needsLayout = true } }
    override func draw(_ dirtyRect: NSRect) { NSColor(white: 0.07, alpha: 1).setFill(); bounds.fill() }
    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        if let focusedID, let focused = tiles.first(where: { $0.camera.id == focusedID }) {
            for tile in tiles { tile.isHidden = tile !== focused }
            focused.frame = bounds.insetBy(dx: 8, dy: 8); focused.needsLayout = true
            return
        }
        tiles.forEach { $0.isHidden = false }
        let cols = min(columns, tiles.count), rows = (tiles.count + cols - 1) / cols
        let gap: CGFloat = 8
        let width = (bounds.width - CGFloat(cols + 1) * gap) / CGFloat(cols)
        let height = (bounds.height - CGFloat(rows + 1) * gap) / CGFloat(rows)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: gap + CGFloat(index % cols) * (width + gap),
                                y: gap + CGFloat(index / cols) * (height + gap), width: max(1, width), height: max(1, height))
            tile.needsLayout = true
        }
    }
}

final class SettingsEditor {
    private let initial: Settings
    private let host: NSTextField
    private let port: NSTextField
    private let username: NSTextField
    private let password = NSSecureTextField()
    private let cache: NSTextField
    private var cameraRows: [(NSTextField, NSTextField, NSButton)] = []
    private let alert = NSAlert()
    private var cancelled = false
    var onSave: ((Settings, String?) throws -> Void)?

    init(settings: Settings) {
        initial = settings
        host = NSTextField(string: settings.host); host.placeholderString = "NVR IP address or hostname"
        port = NSTextField(string: String(settings.port))
        username = NSTextField(string: settings.username)
        cache = NSTextField(string: String(settings.cacheMS))
        password.placeholderString = "Blank keeps the saved password"
        alert.messageText = "NVR & cameras"
        alert.informativeText = "All six channels use this NVR. Enable Sub Stream 1/2 in Dahua before selecting them. Passwords are stored in Keychain."
        alert.addButton(withTitle: "Save & apply"); alert.addButton(withTitle: "Cancel")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 415))
        func fieldRow(_ name: String, _ field: NSView, y: CGFloat) {
            let caption = label(name); caption.frame = NSRect(x: 0, y: y + 3, width: 120, height: 22)
            field.frame = NSRect(x: 125, y: y, width: 350, height: 25)
            view.addSubview(caption); view.addSubview(field)
        }
        fieldRow("NVR address", host, y: 380)
        fieldRow("RTSP port", port, y: 347)
        fieldRow("Username", username, y: 314)
        fieldRow("Password", password, y: 281)
        fieldRow("Buffer (ms)", cache, y: 248)
        let titles = label("Camera name                              Channel       Show", size: 12, bold: true)
        titles.frame = NSRect(x: 0, y: 211, width: 485, height: 24); view.addSubview(titles)
        for (index, camera) in settings.cameras.enumerated() {
            let name = NSTextField(string: camera.name), channel = NSTextField(string: String(camera.channel))
            let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            enabled.state = camera.enabled ? .on : .off
            let y = CGFloat(178 - index * 30)
            name.frame = NSRect(x: 0, y: y, width: 295, height: 24)
            channel.frame = NSRect(x: 310, y: y, width: 75, height: 24)
            enabled.frame = NSRect(x: 420, y: y, width: 30, height: 24)
            [name, channel, enabled].forEach(view.addSubview)
            cameraRows.append((name, channel, enabled))
        }
        alert.accessoryView = view
    }
    func show(on window: NSWindow) {
        guard !cancelled else { return }
        alert.beginSheetModal(for: window) { [self] response in
            guard !cancelled, response == .alertFirstButtonReturn else { return }
            do {
                var updated = initial
                updated.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.username = username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let p = Int(port.stringValue), let c = Int(cache.stringValue) else {
                    throw GridError.message("Port and buffer must be whole numbers.")
                }
                updated.port = p; updated.cacheMS = c
                for (index, row) in cameraRows.enumerated() {
                    guard let channel = Int(row.1.stringValue) else { throw GridError.message("Channels must be whole numbers.") }
                    updated.cameras[index].name = row.0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.cameras[index].channel = channel; updated.cameras[index].enabled = row.2.state == .on
                }
                try updated.validate()
                try onSave?(updated, password.stringValue.isEmpty ? nil : password.stringValue)
            } catch {
                let errorAlert = NSAlert(); errorAlert.messageText = "Settings were not applied"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.beginSheetModal(for: window) { _ in self.show(on: window) }
            }
        }
    }
    func cancel() { cancelled = true; password.stringValue = "" }
}
