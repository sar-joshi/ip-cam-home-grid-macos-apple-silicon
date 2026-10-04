import AppKit

@main struct PlaybackSmoke {
    static func main() throws {
        let checkRecovery = CommandLine.arguments.contains("--reconnect")
        var server: Process?
        func startServer() throws {
            guard let fixture = ProcessInfo.processInfo.environment["HOMEGRID_TEST_FIXTURE"] else {
                throw GridError.message("Set HOMEGRID_TEST_FIXTURE to an H.264 MP4 test file for the reconnection test.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/VLC.app/Contents/MacOS/VLC")
            process.arguments = ["--intf", "dummy", "--no-audio", "--loop", "--rtsp-host=127.0.0.1",
                                 "--sout", "#rtp{sdp=rtsp://127.0.0.1:8554/test}", "--sout-keep", fixture]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); server = process
        }
        if checkRecovery { try startServer() }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let engine = try VLCEngine()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "HomeGrid · local RTSP verification"
        let grid = GridView(frame: window.contentView!.bounds)
        grid.autoresizingMask = [.width, .height]; window.contentView!.addSubview(grid)
        let tiles = (1...6).map { CameraTile(camera: Camera(name: "Test camera \($0)", channel: $0)) }
        tiles.forEach(grid.addSubview); grid.tiles = tiles
        window.center(); window.makeKeyAndOrderFront(nil)
        var live = Set<Int>(), offline = Set<Int>()
        var phase = 0, ticks = 0, restartAt = 0
        let url = "rtsp://127.0.0.1:8554/test"
        for (index, tile) in tiles.enumerated() {
            let player = CameraPlayer(engine: engine, canvas: tile.canvas)
            player.onStatus = { text in
                tile.status.stringValue = text
                if text == "Live" { live.insert(index) } else { live.remove(index) }
                if text.hasPrefix("Offline") { offline.insert(index) }
            }
            tile.player = player; player.play(url: url, cacheMS: 350, muted: true)
        }
        func finish(_ success: Bool) {
            if let server, server.isRunning { server.terminate() }
            let group = DispatchGroup()
            for tile in tiles { group.enter(); tile.player?.dispose { group.leave() } }
            group.notify(queue: .main) {
                print(success ? "PASS: six simultaneous RTSP players; mute changes; stop/start; clean teardown." : "FAIL: RTSP playback did not recover; live=\(live.count), offline=\(offline.count)")
                exit(success ? 0 : 1)
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            ticks += 1; tiles.forEach { $0.player?.poll() }
            if phase == 0 && live.count == 6 {
                print("Six RTSP players live. Checking stop/start."); fflush(stdout)
                tiles.forEach { $0.player?.setMuted(false); $0.player?.setMuted(true); $0.player?.stop() }
                live.removeAll(); phase = 1; restartAt = ticks + 3
            } else if phase == 1 && ticks >= restartAt {
                tiles.forEach { $0.player?.play(url: url, cacheMS: 550, muted: true) }
                phase = 2
            } else if phase == 2 && live.count == 6 {
                if checkRecovery {
                    offline.removeAll(); phase = 3
                    server?.terminate()
                    print("Stopped the test RTSP server; waiting for all six streams to detect disconnection."); fflush(stdout)
                } else { timer.invalidate(); DispatchQueue.main.async { finish(true) } }
            } else if phase == 3 && offline.count == 6 {
                phase = 4
                print("All six players detected the interruption. Restarting the test server."); fflush(stdout)
                DispatchQueue.main.async {
                    do { try startServer() } catch { timer.invalidate(); finish(false) }
                }
            } else if phase == 4 && live.count == 6 {
                print("All six streams automatically reconnected."); fflush(stdout)
                timer.invalidate(); DispatchQueue.main.async { finish(true) }
            }
            if ticks >= (checkRecovery ? 120 : 55) { timer.invalidate(); DispatchQueue.main.async { finish(false) } }
        }
        _ = timer; app.run()
    }
}
