#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="build/LidGlass.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/swift-cache build/LidGlass.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/LidGlass.png --out "build/LidGlass.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Assets/LidGlass.png --out "build/LidGlass.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/LidGlass.iconset -o "$APP/Contents/Resources/LidGlass.icns"
swiftc -O -target arm64-apple-macos14.0 -module-cache-path build/swift-cache \
  -framework AppKit -framework IOKit -framework ScreenCaptureKit -framework MetalKit \
  -framework CoreImage main.swift -o "$APP/Contents/MacOS/LidGlass"
cp Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
