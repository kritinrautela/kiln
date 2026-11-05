#!/bin/zsh
# Builds Kiln.app (Apple silicon, macOS 26+) into build/, plus a zip ready for a GitHub release.
set -e
cd "$(dirname "$0")"
APP=build/Kiln.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ! -f build/Kiln.icns ]; then
  swiftc -O tools/icon.swift -o build/make-icon
  ./build/make-icon build/Kiln.iconset
  iconutil -c icns build/Kiln.iconset -o build/Kiln.icns
fi
if ! log=$(swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/Kiln" 2>&1); then
  echo "$log" | grep -E "error" -A3; echo "build failed"; exit 1
fi
test -x "$APP/Contents/MacOS/Kiln"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/Kiln.icns "$APP/Contents/Resources/Kiln.icns"
codesign --force --sign - "$APP"
(cd build && ditto -c -k --keepParent Kiln.app Kiln.zip)
echo "built $APP and build/Kiln.zip"
