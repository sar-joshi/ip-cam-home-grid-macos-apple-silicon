#!/bin/zsh
set -eu
cd "$(dirname "$0")"
vlc_root=/Applications/VLC.app/Contents/MacOS
if [[ ! -f "$vlc_root/include/vlc/vlc.h" ]]; then
  print -u2 'Install VLC from https://www.videolan.org/vlc/ at /Applications/VLC.app first.'
  exit 1
fi
mkdir -p .build/CVLC HomeGrid.app/Contents/MacOS
cat > .build/CVLC/module.modulemap <<EOF
module CVLC [system] {
  header "$vlc_root/include/vlc/vlc.h"
  link "vlc"
  export *
}
EOF
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -I .build/CVLC -Xcc -I -Xcc "$vlc_root/include" -L "$vlc_root/lib" -lvlc \
  -Xlinker -rpath -Xlinker "$vlc_root/lib" \
  -framework AppKit -framework Security -framework LocalAuthentication Sources/*.swift \
  -o HomeGrid.app/Contents/MacOS/HomeGrid
cp Info.plist HomeGrid.app/Contents/Info.plist
codesign --force --sign - HomeGrid.app
print 'Built HomeGrid.app. Run: open HomeGrid.app'
