#!/bin/zsh
# Builds Tuck.app into ./build.
# Usage: ./build.sh            build for this Mac
#        ./build.sh install    build + copy to /Applications + launch
#        ./build.sh release    universal (Apple Silicon + Intel) build + build/Tuck.zip
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Tuck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift Tools/make_icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

compile() { # $1 = arch, $2 = output
  swiftc -O -swift-version 5 \
    -target "$1-apple-macos13.0" \
    -framework AppKit -framework ServiceManagement -framework QuickLookThumbnailing -framework Carbon \
    Sources/*.swift -o "$2"
}

if [[ "${1:-}" == "release" ]]; then
  compile arm64 build/Tuck-arm64
  compile x86_64 build/Tuck-x86_64
  lipo -create build/Tuck-arm64 build/Tuck-x86_64 -output "$APP/Contents/MacOS/Tuck"
  rm build/Tuck-arm64 build/Tuck-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/Tuck"
fi

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "release" ]]; then
  rm -f build/Tuck.zip
  ditto -c -k --keepParent "$APP" build/Tuck.zip
  echo "Packed build/Tuck.zip"
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x Tuck 2>/dev/null || true
  rm -rf /Applications/Tuck.app
  cp -R "$APP" /Applications/
  open /Applications/Tuck.app
  echo "Installed to /Applications/Tuck.app"
fi
