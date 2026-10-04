#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
swiftc -swift-version 5 Sources/Models.swift Tests/ModelTests.swift -framework Security -o .build/ModelTests
.build/ModelTests
if [[ "${1:-}" == "--rtsp" || "${1:-}" == "--reconnect" ]]; then
  # Supply a looped H.264 RTSP test feed at rtsp://127.0.0.1:8554/test first.
  vlc_root=/Applications/VLC.app/Contents/MacOS
  swiftc -swift-version 5 -I .build/CVLC -Xcc -I -Xcc "$vlc_root/include" \
    -L "$vlc_root/lib" -lvlc -Xlinker -rpath -Xlinker "$vlc_root/lib" \
    -framework AppKit -framework Security Sources/Models.swift Sources/Playback.swift \
    Sources/Interface.swift Tests/PlaybackSmoke.swift -o .build/PlaybackSmoke
  if [[ "$1" == "--reconnect" ]]; then
    .build/PlaybackSmoke --reconnect
  else
    .build/PlaybackSmoke
  fi
fi
