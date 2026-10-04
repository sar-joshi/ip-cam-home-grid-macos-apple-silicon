# HomeGrid

A small native macOS viewer for six Dahua NVR channels. Written in Swift and AppKit, with a separate libVLC player for each visible camera. No GridPlayer code or repository was cloned. The app uses the VLC installation you already have at `/Applications/VLC.app`.

## Start using it

1. Open `HomeGrid.app`. You can move it to Applications; keep VLC installed at `/Applications/VLC.app`.
2. Open **NVR & cameras…**, enter the NVR's local IP address, RTSP port (usually 554), username and password. Enter only the hostname/IP in the address field.
3. Name the six cameras and set their NVR channel numbers. Choose which cameras to show, then click **Save & apply**. Playback starts automatically.
4. Select cameras from **Cameras**, and choose 1, 2 or 3 columns. The grid fills the available window; showing six cameras with three columns gives a 3 × 2 layout.
5. Use each camera's quality menu to choose **Main · 0**, **Sub 1 · 1**, or **Sub 2 · 2**. These change `subtype` in the RTSP request; they do not alter the NVR's encoding settings.
6. Drag the dotted grip at a tile's top-left onto another tile to swap their positions. The playback views move without reconnecting.
7. Cameras start muted. Use **Unmute** per camera or **Mute all** globally. Audio must be enabled and supported by the camera/NVR for sound to be available.
8. **Stop** releases stream connections and decoders. **Start** reconnects the selected cameras. The macOS green window button provides full-screen viewing.

The password is stored in macOS Keychain, under service `local.homegrid.nvr`. Other preferences are saved to `~/Library/Application Support/HomeGrid/settings.json`, with owner-only file permissions. Camera order, visibility, names, channels, quality, mute, column count, connection details and buffer size persist. On the next launch, saved selected cameras reconnect automatically. A blank password field keeps the saved password for the same NVR/account. Enter the password again if you change the address, port or username. RTSP URLs and passwords are not written to application logs or settings.

## Suggested Dahua encoding settings

These are starting points to set manually in the Dahua web app. Resolution and codec choices depend on your specific cameras; apply each profile per channel.

| Profile | Resolution | Codec | Frame rate | Bitrate starting point |
| --- | --- | --- | --- | --- |
| Main (`subtype=0`) | Highest native resolution; your screenshot shows 3840 × 2160 | Standard H.265 for native playback | 25 fps if supported | 4096–8192 kbps; try 6144 and judge detail during motion |
| Sub 1 (`subtype=1`) | 1280 × 720 if available; otherwise the best offered substream resolution | Standard H.264 | 10–15 fps | 512–1536 kbps; try 1024 for 720p, 512 for D1, or 384 for CIF |
| Sub 2 (`subtype=2`) | 640 × 360 or 352 × 288, whichever is offered | Standard H.264 | 8–10 fps | 256–512 kbps; try 384 |

Use CBR for a predictable network load on substreams. If available, set the I-frame interval to one or two seconds: at 15 fps, try an interval of 15–30 frames. Use standard codec modes on substreams and disable AI/Smart Codec for the initial compatibility test, especially if you plan to add browser playback later. Keep your existing main stream if its current appearance and VLC playback are already satisfactory; higher main-stream bitrate also increases recording storage use.

Your screenshot has Sub Stream 1 set to CIF (352 × 288), 15 fps and 384 kbps. That is suitable for a light overview, but it cannot show 720p detail. Check its resolution dropdown before changing it. Some Dahua models offer different maximum resolutions for Sub 1 and Sub 2; subtype numbers alone do not imply a particular quality. In the screenshot Sub Stream 2 appears greyed out: verify that your camera/NVR supports and enables it before selecting **Sub 2**. An unavailable substream will show offline and retry.

For the six-camera overview, start with Sub 1 on every tile. Switch individual tiles to Main when you need detail. Six concurrent 4K streams need considerably more decoding and network capacity than six substreams.

The app uses RTSP over TCP and a 350 ms buffer by default. If playback stutters, try 600–1000 ms in **NVR & cameras…**. Increasing the buffer adds latency. Offline or stalled feeds retry automatically, with a delay capped at 30 seconds. A stream with no new decoded video frames for 20 seconds is restarted.

## What is included

- Six configurable NVR channels; any subset can be visible and playing.
- Separate native video surfaces and hardware decoding requested through VLC.
- Per-camera stream quality and mute; global mute.
- Drag to swap cameras, persistent settings, and Keychain credentials.
- Automatic retry for connection failures and stalled video.
- Direct RTSP input only. No recording, playback timeline, PTZ, motion detection or cloud service.

This is a locally built, ad hoc signed application, not an Apple-notarized distribution. Its executable is about 324 KB in this build; VLC supplies the media engine separately. It currently assumes one NVR/account for all six channels. Source is included so the app can be reviewed and rebuilt.

The app does not need the Dahua serial-number QR code. For home-network use, no router forwarding or internet deployment is needed. RTSP in this version is not encrypted; keep access on your trusted home network. A camera account limited to live viewing is a suitable choice.

## Browser access later

Ordinary browser video elements cannot play this RTSP URL directly. A practical browser version would use:

`Dahua NVR — RTSP → local media gateway — WebRTC → browser grid`

The app's camera inputs can remain RTSP-only, but browser delivery must use a browser-supported protocol. [MediaMTX supports browser playback through WebRTC and HLS](https://mediamtx.org/docs/read/web-browsers). WebRTC is the better initial choice for live viewing; HLS generally adds more latency. [Codec compatibility varies by browser](https://mediamtx.org/docs/features/webrtc-specific-features): H.264 without B-frames is the safer starting point, while H.265 is conditional. The gateway can relay compatible video without re-encoding; incompatible video or audio would need conversion, which adds CPU work.

Since you only need home-network viewing, host the interface and gateway at home on a Mac, NAS or small computer that stays on while you use it. Next.js is possible. A Vercel-hosted interface would still need the home gateway, secure browser access to it, authentication and suitable CORS/local-network permissions. Vercel does not make a private NVR reachable by itself, and its [function execution limits](https://vercel.com/docs/functions/limitations) make it unsuitable as the permanent camera media process. Nothing has been deployed or exposed online in this version.

## Build and verify

Requires Apple Command Line Tools with Swift, and the matching Apple Silicon or Intel VLC 3 installation at `/Applications/VLC.app`. The current compiled app is Apple Silicon. The build script compiles for the machine's architecture with a macOS 13 deployment target.

```sh
./build.sh
open HomeGrid.app
./test.sh
```

Model tests cover escaping special characters in credentials, all three subtype values, settings round-trips and validation. They do not read or write your NVR password.

For a six-player playback test, supply a synthetic H.264 RTSP stream at `rtsp://127.0.0.1:8554/test` and run `./test.sh --rtsp`. To test an intentional server interruption, set `HOMEGRID_TEST_FIXTURE` to an H.264 MP4 file and run `./test.sh --reconnect`. That test owns its local VLC server, stops it, restarts it and checks that all six players recover. Port 8554 must be free. These tests do not access the NVR or its saved credentials.

Verified in this session: compilation and launch; native grid/settings UI; URL and settings tests; six simultaneous local RTSP players; stop/start and reconnection. After the NVR was configured locally by you, all six real camera tiles reported **Live**. Main/Sub 2 codec and resolution limits still depend on the camera/NVR configuration; no encoder settings were changed by the app.

Reference: [GridPlayer's architecture and features](https://github.com/vzhd1701/gridplayer), and [Dahua's RTSP channel/subtype documentation](https://dahuawiki.com/index.php?title=Remote_Access%2FRTSP_via_VLC).
