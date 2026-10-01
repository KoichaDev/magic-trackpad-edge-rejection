#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build --product TrackpadEdges -c release --scratch-path "$PWD/.build" -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache"
app="$PWD/build/TrackpadEdges.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$PWD/.build/release/TrackpadEdges" "$app/Contents/MacOS/TrackpadEdges"
cp Info.plist "$app/Contents/Info.plist"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier dev.koicha.trackpad-edges "$app"
printf '%s\n' "$app"
