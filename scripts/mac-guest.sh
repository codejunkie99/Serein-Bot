#!/bin/bash
set -euo pipefail
# Build a guest-only application. This is a native Swift binary and needs no Python or Xcode
# tools installed in the guest. Its physical-host guard runs before any app or input API.
BINARY="$1"
RESOURCES="$2"
GUEST_APP="$RESOURCES/MacGuest/Serein Computer.app"
# The guest updates itself only when this number changes, while the host accepts only the exact
# binary it ships. Signing makes every build's binary new, even when its code is unchanged, so
# the number must change on every build too; a hash of the unsigned binary stayed the same and
# left the Mac stuck "connecting" with its old helper. The build time does change every build.
BUILD_NUMBER="$(date +%s)"
mkdir -p "$GUEST_APP/Contents/MacOS" "$GUEST_APP/Contents/Resources"
cp "$BINARY" "$GUEST_APP/Contents/MacOS/serein-mac-guest"
cp docs/licenses/terminal-mac-MIT.txt "$GUEST_APP/Contents/Resources/terminal-mac-MIT.txt"
cp docs/licenses/Cua-MIT.txt "$GUEST_APP/Contents/Resources/Cua-MIT.txt"
cat > "$GUEST_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>serein-mac-guest</string>
<key>CFBundleIdentifier</key><string>pro.serein.computer-guest</string>
<key>CFBundleName</key><string>Serein Computer</string>
<key>CFBundleDisplayName</key><string>Serein Computer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSScreenCaptureUsageDescription</key><string>Let Serein see this virtual Mac's screen. Your physical Mac is not captured.</string>
</dict></plist>
PLIST
