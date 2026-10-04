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
                print(success ? "PASS: six decoded RTSP feeds; per-camera stop/resume; focus resource release and restore; reconnection; clean teardown." : "FAIL: RTSP playback did not recover; live=\(live.count), offline=\(offline.count)")
                exit(success ? 0 : 1)
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            ticks += 1; tiles.forEach { $0.player?.poll() }
            if phase == 0 && live.count == 6 {
                print("Six RTSP players live. Checking per-camera stop/resume."); fflush(stdout)
                tiles[0].player?.setMuted(false); tiles[0].player?.setMuted(true); tiles[0].player?.stop()
                phase = 1; restartAt = ticks + 3
            } else if phase == 1 && ticks >= restartAt {
                phase = 2
                precondition(live.count == 5 && !live.contains(0))
                tiles[0].player?.inspect { allocated, _ in
                    precondition(!allocated)
                    tiles[0].player?.play(url: url, cacheMS: 550, muted: true)
                }
            } else if phase == 2 && live.count == 6 {
                grid.focusedID = tiles[0].camera.id; grid.layoutSubtreeIfNeeded()
                precondition(grid.tiles.filter { !$0.isHidden }.count == 1)
                for index in 1...5 { tiles[index].player?.stop() }
                phase = 3; restartAt = ticks + 3
            } else if phase == 3 && ticks >= restartAt {
                precondition(live == [0])
                phase = 4
                let stopped = DispatchGroup()
                for index in 1...5 {
                    stopped.enter()
                    tiles[index].player?.inspect { allocated, _ in precondition(!allocated); stopped.leave() }
                }
                stopped.notify(queue: .main) {
                    tiles[0].player?.inspect { allocated, frames in
                        precondition(allocated && frames > 0)
                        grid.focusedID = nil; grid.layoutSubtreeIfNeeded()
                        precondition(grid.tiles.filter { !$0.isHidden }.count == 6)
                        tiles[1].camera.streaming = false
                        for index in 2...5 { tiles[index].player?.play(url: url, cacheMS: 350, muted: true) }
                    }
                }
            } else if phase == 4 && live.count == 5 {
                precondition(!live.contains(1))
                phase = 5
                tiles[1].player?.inspect { allocated, _ in
                    precondition(!allocated && !tiles[1].camera.streaming)
                    tiles[1].camera.streaming = true
                    tiles[1].player?.play(url: url, cacheMS: 350, muted: true)
                }
            } else if phase == 5 && live.count == 6 {
                if checkRecovery {
                    offline.removeAll(); phase = 6
                    server?.terminate()
                    print("Stopped the test RTSP server; waiting for all six streams to detect disconnection."); fflush(stdout)
                } else { timer.invalidate(); DispatchQueue.main.async { finish(true) } }
            } else if phase == 6 && offline.count == 6 {
                phase = 7
                print("All six players detected the interruption. Restarting the test server."); fflush(stdout)
                DispatchQueue.main.async {
                    do { try startServer() } catch { timer.invalidate(); finish(false) }
                }
            } else if phase == 7 && live.count == 6 {
                print("All six streams automatically reconnected."); fflush(stdout)
                timer.invalidate(); DispatchQueue.main.async { finish(true) }
            }
            if ticks >= (checkRecovery ? 120 : 55) { timer.invalidate(); DispatchQueue.main.async { finish(false) } }
        }
        _ = timer; app.run()
    }
}
