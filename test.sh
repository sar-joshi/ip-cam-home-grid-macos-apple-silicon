#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
swiftc -swift-version 5 Sources/Models.swift Tests/ModelTests.swift -framework Security -o .build/ModelTests
.build/ModelTests
swiftc -swift-version 5 Sources/Authentication.swift Tests/AuthenticationTests.swift -framework LocalAuthentication -o .build/AuthenticationTests
.build/AuthenticationTests
vlc_root=/Applications/VLC.app/Contents/MacOS
if [[ ! -f .build/CVLC/module.modulemap ]]; then ./build.sh; fi
swiftc -swift-version 5 -I .build/CVLC -Xcc -I -Xcc "$vlc_root/include" \
  -L "$vlc_root/lib" -lvlc -Xlinker -rpath -Xlinker "$vlc_root/lib" \
  -framework AppKit -framework Security -framework LocalAuthentication \
  Sources/Models.swift Sources/Authentication.swift Sources/Playback.swift Sources/Interface.swift \
  Sources/AppController.swift Tests/SessionTests.swift -o .build/SessionTests
.build/SessionTests
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
