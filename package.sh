#!/bin/zsh
set -eu
cd "${0:A:h}"

APP="build/LidGlass.app"
if [[ ! -d "$APP" ]]; then
  printf '请先运行 zsh build.sh\n' >&2
  exit 1
fi
codesign --verify --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="LidGlass-${VERSION}-arm64-preview"
mkdir -p dist
STAGING=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
chmod 755 "$STAGING"
ditto --norsrc --noextattr "$APP" "$STAGING/LidGlass.app"
ln -s /Applications "$STAGING/Applications"
cp docs/安装说明.txt "$STAGING/安装说明.txt"
cp LICENSE "$STAGING/LICENSE.txt"
ditto -c -k --norsrc --noextattr --keepParent "$STAGING/LidGlass.app" "dist/$NAME.zip"
hdiutil create -volname "LidGlass $VERSION" -srcfolder "$STAGING" -ov -format UDZO "dist/$NAME.dmg"
(
  cd dist
  shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt
)
printf 'Packages: dist/%s.{dmg,zip}\n' "$NAME"
