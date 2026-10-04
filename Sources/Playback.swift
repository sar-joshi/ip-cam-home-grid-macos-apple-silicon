import AppKit
import CVLC

final class VLCEngine {
    let instance: OpaquePointer
    init() throws {
        setenv("VLC_PLUGIN_PATH", "/Applications/VLC.app/Contents/MacOS/plugins", 1)
        let options = ["--no-video-title-show", "--no-osd", "--no-snapshot-preview", "--quiet", "--vout=macosx", "--avcodec-hw=any"]
        let strings = options.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let pointers = strings.map { UnsafePointer($0) }
        guard let instance = pointers.withUnsafeBufferPointer({ libvlc_new(Int32($0.count), $0.baseAddress) }) else {
            throw GridError.message("VLC could not start. Install the matching Apple Silicon or Intel VLC at /Applications/VLC.app.")
        }
        self.instance = instance
        // Discard libVLC messages so embedded RTSP credentials cannot be logged.
        libvlc_log_set(instance, { _, _, _, _, _ in }, nil)
    }
    deinit { libvlc_release(instance) }
}

final class CameraPlayer {
    private let engine: VLCEngine
    private let canvas: NSView
    private let queue = DispatchQueue(label: "HomeGrid.player", qos: .userInitiated)
    private var player: OpaquePointer?
    private var media: OpaquePointer?
    private var desiredURL: String?
    private var cache = 350
    private var muted = true
    private var lastFrames: Int32 = -1
    private var lastProgress = Date()
    private var retryAt = Date.distantPast
    private var attempt = 0
    private var disposed = false
    var onStatus: ((String) -> Void)?

    init(engine: VLCEngine, canvas: NSView) { self.engine = engine; self.canvas = canvas }

    func play(url: String, cacheMS: Int, muted: Bool) {
        queue.async {
            guard !self.disposed else { return }
            self.desiredURL = url; self.cache = cacheMS; self.muted = muted; self.attempt = 0
            self.start()
        }
    }
    private func status(_ text: String) { DispatchQueue.main.async { self.onStatus?(text) } }
    private func releasePlayer() {
        if let p = player {
            libvlc_media_player_stop(p)
            libvlc_media_player_set_nsobject(p, nil)
            libvlc_media_player_release(p)
        }
        if let m = media { libvlc_media_release(m) }
        player = nil; media = nil
    }
    private func start() {
        releasePlayer()
        guard let url = desiredURL else { return }
        status(attempt == 0 ? "Connecting…" : "Reconnecting…")
        guard let m = url.withCString({ libvlc_media_new_location(engine.instance, $0) }) else {
            scheduleRetry(); return
        }
        guard let p = libvlc_media_player_new(engine.instance) else {
            libvlc_media_release(m); scheduleRetry(); return
        }
        media = m; player = p
        for option in [":rtsp-tcp", ":network-caching=\(cache)", ":live-caching=\(cache)"] {
            option.withCString { libvlc_media_add_option(m, $0) }
        }
        libvlc_media_player_set_media(p, m)
        libvlc_media_player_set_nsobject(p, Unmanaged.passUnretained(canvas).toOpaque())
        libvlc_audio_set_mute(p, muted ? 1 : 0)
        lastFrames = -1; lastProgress = Date(); retryAt = .distantPast
        if libvlc_media_player_play(p) != 0 { scheduleRetry() }
    }
    private func scheduleRetry() {
        releasePlayer()
        attempt += 1
        let seconds = min(30, Int(pow(2.0, Double(min(attempt, 5)))))
        retryAt = Date().addingTimeInterval(Double(seconds))
        status("Offline · retry in \(seconds)s")
    }
    func poll() {
        queue.async {
            guard !self.disposed, self.desiredURL != nil else { return }
            guard let p = self.player else {
                if Date() >= self.retryAt { self.start() }; return
            }
            let state = libvlc_media_player_get_state(p)
            var stats = libvlc_media_stats_t()
            if let m = self.media, libvlc_media_get_stats(m, &stats) != 0, stats.i_decoded_video > self.lastFrames {
                self.lastFrames = stats.i_decoded_video; self.lastProgress = Date(); self.attempt = 0
            }
            if state == libvlc_Error || state == libvlc_Ended || Date().timeIntervalSince(self.lastProgress) > 20 {
                self.scheduleRetry()
            } else if state == libvlc_Playing { self.status("Live") }
        }
    }
    func setMuted(_ value: Bool) {
        queue.async { self.muted = value; if let p = self.player { libvlc_audio_set_mute(p, value ? 1 : 0) } }
    }
    func stop() {
        queue.async { self.desiredURL = nil; self.releasePlayer(); self.status("Stopped") }
    }
    func dispose(completion: (() -> Void)? = nil) {
        onStatus = nil
        // VLC may synchronously dispatch video teardown to the main thread.
        // Never stop or wait for its worker queue from the UI thread.
        queue.async {
            self.disposed = true; self.desiredURL = nil; self.releasePlayer()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
}
