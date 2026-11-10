#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -m)" == arm64 ]]
export HOMEBREW_NO_AUTO_UPDATE=1
if ! brew list --versions libusb >/dev/null; then brew install libusb; fi
usb="$(brew --prefix libusb)"
export PKG_CONFIG_PATH="$usb/lib/pkgconfig"
swift build -c release -Xswiftc -warnings-as-errors -Xcc "-I$usb/include/libusb-1.0" -Xcc -Wall -Xcc -Wextra -Xcc -Werror
binary="$(swift build -c release --show-bin-path)/MacMTP"
[[ "$(lipo -archs "$binary")" == arm64 ]]
mkdir -p dist
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/MacMTP.app/Contents"
mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources"
cp "$binary" "$app/MacOS/MacMTP"
library="$app/Frameworks/libusb-1.0.0.dylib"
cp -L "$usb/lib/libusb-1.0.0.dylib" "$library"
chmod u+w "$library"
dependency="$(otool -L "$binary" | awk '/libusb-1[.]0[.]0[.]dylib/ {print $1; exit}')"
test -n "$dependency"
codesign --remove-signature "$app/MacOS/MacMTP"
install_name_tool -change "$dependency" '@executable_path/../Frameworks/libusb-1.0.0.dylib' "$app/MacOS/MacMTP"
cp "$usb/COPYING" "$app/Resources/libusb-LICENSE.txt"
iconset="$stage/work/MacMTP.iconset"
mkdir -p "$iconset"
swift AppIcon.swift "$stage/work/master.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/work/master.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$stage/work/master.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Resources/MacMTP.icns"
rm -rf "$stage/work"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacMTP</string>
<key>CFBundleIdentifier</key><string>com.meir.macmtp</string>
<key>CFBundleName</key><string>MacMTP</string>
<key>CFBundleIconFile</key><string>MacMTP.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
plutil -lint "$app/Info.plist"
codesign --force --sign - "$library"
codesign --force --sign - "$stage/MacMTP.app"
codesign --verify --deep --strict "$stage/MacMTP.app"
ln -s /Applications "$stage/Applications"
rm -f dist/MacMTP.dmg
diskutil image create from --format UDZO --volumeName MacMTP "$stage" "$PWD/dist/MacMTP.dmg"
diskutil image info "$PWD/dist/MacMTP.dmg"
test -s dist/MacMTP.dmg
