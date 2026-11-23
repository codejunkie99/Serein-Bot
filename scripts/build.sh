#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${SEREIN_NOTARIZE:-0}" = 1 ]; then
  BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
  ARCH=universal
else
  BUILD_ARGS=(-c release)
  ARCH="$(uname -m)"
fi
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
# The pinned Cua Driver for the built-in computer's seed, checked against its pins (or none).
RESOURCE_BUNDLE="$BIN/Serein_Serein.bundle"
RESOURCE_DIR="$RESOURCE_BUNDLE"
if [ -d "$RESOURCE_BUNDLE/Contents/Resources" ]; then
  RESOURCE_DIR="$RESOURCE_BUNDLE/Contents/Resources"
  # Older builds staged these generated files outside Foundation's resource directory.
  for name in cua-driver cua-driver-amd64 cua-driver-crates.md; do
    rm -f "$RESOURCE_BUNDLE/Computer/$name"
  done
fi
[ -f "$RESOURCE_DIR/Computer/serein-helper.py" ] || { echo "Missing Computer resources in $RESOURCE_DIR" >&2; exit 1; }
# An incremental build can retain a removed resource from the paid tree.
for name in cloud-entry.sh serein-gate.py; do
  [ ! -e "$RESOURCE_DIR/Computer/$name" ] || { echo "Unexpected managed-cloud resource: $name; build from clean Free inputs." >&2; exit 1; }
done
scripts/cua-driver.sh "$RESOURCE_DIR/Computer"
DIST_DIR="${SEREIN_DIST_DIR:-$PWD/dist}"
mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Serein.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/serein-process-host" "$APP/Contents/MacOS/serein-process-host"
cp "$BIN/Serein" "$APP/Contents/MacOS/Serein"
cp "$BIN/serein-browser-mcp" "$APP/Contents/MacOS/serein-browser-mcp"
cp "$BIN/serein-agent" "$APP/Contents/MacOS/serein-agent"
cp "$BIN/serein-mac-provisioner" "$APP/Contents/MacOS/serein-mac-provisioner"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp scripts/pro.serein.mac-provisioner.plist "$APP/Contents/Library/LaunchDaemons/"
cp -R "$BIN/Serein_Serein.bundle" "$APP/Contents/Resources/"
bash scripts/mac-guest.sh "$BIN/serein-mac-guest" "$APP/Contents/Resources"
# Sparkle updates release builds. Preserve its framework symlinks.
mkdir -p "$APP/Contents/Frameworks"
ditto ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Serein"
cp docs/licenses/Sparkle-LICENSE.txt "$APP/Contents/Resources/Sparkle-LICENSE.txt"
# transcribe.cpp runs the dictation model. SwiftPM names the artifact folder after the checkout.
ditto .build/artifacts/*/CTranscribe/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework "$APP/Contents/Frameworks/CTranscribe.framework"
cp docs/licenses/transcribe.cpp-LICENSES.txt "$APP/Contents/Resources/transcribe.cpp-LICENSES.txt"
python3 scripts/package_notices.py "$APP/Contents/Resources"
ICON_WORK="$STAGE/Serein.iconset"
swift scripts/icon.swift "$ICON_WORK"
iconutil -c icns "$ICON_WORK" -o "$APP/Contents/Resources/Serein.icns"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Serein</string>
<key>CFBundleIdentifier</key><string>local.serein.browser</string>
<key>CFBundleName</key><string>Serein</string>
<key>CFBundleIconFile</key><string>Serein</string>
<key>CFBundleDisplayName</key><string>Serein Free</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Allow camera access only for a website you approve.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Share your approximate location only with a website you approve.</string>
<key>NSAppleEventsUsageDescription</key><string>Serein does the Mac app tasks you ask for, such as reading your calendar or adding a reminder. It asks you first unless you chose Only risky steps in Settings › Assistants, and always asks before sending or deleting. Serein also reads the open tabs of your other browser when you ask it to bring them.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>When you turn on Calendar in Settings › Connections, Serein reads your events to answer you. It adds, changes or deletes an event only after you allow it on a card.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>When you turn on Reminders in Settings › Connections, Serein reads your reminders to answer you. It adds one only after you allow it on a card.</string>
<key>NSContactsUsageDescription</key><string>When you turn on Contacts in Settings › Connections, Serein looks up names, email addresses and phone numbers for you. It never changes your contacts.</string>
<key>NSLocalNetworkUsageDescription</key><string>Serein reaches sites and computers on your local network only when you open one or add your own computer in Settings › Serein's computer.</string>
<key>NSMicrophoneUsageDescription</key><string>Dictate a request to Serein using on-device speech recognition.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn your voice into text on this Mac when you press the microphone button, hold Serein’s shortcut, or say “Serein” after turning that on in Settings › Voice.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
PLIST
# Only a release updates itself, from the newest GitHub release (scripts/release.sh publishes
# appcast.xml there). A local build has no feed, so it never replaces itself.
if [ "${SEREIN_NOTARIZE:-0}" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/codejunkie99/Serein-Bot/releases/latest/download/appcast.xml" \
    -c "Add :SUPublicEDKey string Cvu8zrIxWdP+DO1H6jtbfTbFjMtncUu8lTj/w9rKIvU=" "$APP/Contents/Info.plist"
fi
xattr -cr "$APP"
# A real identity when one exists: macOS ties Accessibility, Automation and Screen Recording
# grants to the signer, so an ad-hoc signature loses them on every rebuild.
if [ "${SEREIN_NOTARIZE:-0}" = 1 ]; then
  TEAM_ID="${SEREIN_TEAM_ID:-Z4TS3CNN32}"
  IDENTITY="${SEREIN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o "\"Developer ID Application: [^\"]* (${TEAM_ID})\"" | head -1 | tr -d '"' || true)}"
  NOTARY_PROFILE="${SEREIN_NOTARY_PROFILE:-serein-notary}"
  [ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate in the keychain (Xcode > Settings > Accounts > Manage Certificates)." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || { echo "Notary profile '$NOTARY_PROFILE' missing; run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id <TEAMID> --password <app-specific-password>" >&2; exit 1; }
  for bin in serein-process-host serein-browser-mcp serein-agent serein-mac-provisioner; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/$bin"
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/MacGuest/Serein Computer.app"
  # Sparkle's helpers come with an ad hoc signature. Each gets ours, inside out. The downloader
  # keeps its own entitlements; --deep would strip them.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/CTranscribe.framework"
  codesign --force --options runtime --timestamp --entitlements scripts/Serein.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  codesign -dv --verbose=4 "$APP" 2>&1 | grep -Fxq "TeamIdentifier=${TEAM_ID}" || {
    echo "In-place release requires signing team (${TEAM_ID})." >&2
    exit 1
  }
  ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$STAGE/notarize.zip"
  xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$STAGE/notary.log"
  grep -q 'status: Accepted' "$STAGE/notary.log" || { echo "Notarization failed; inspect with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2; exit 1; }
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
else
  IDENTITY="${SEREIN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}"
  # No Apple Development certificate: use the Developer ID one, as releases do. Serein's Mac only
  # takes a guest helper update signed by the same team as the helper it runs, so an ad-hoc
  # build after a signed one leaves that Mac stuck "Connecting" with its old helper.
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
  fi
  [ -n "$IDENTITY" ] || echo "warning: no signing certificate; ad-hoc signing. Serein's Mac will not take this build's helper if it last ran a signed one." >&2
  # Resource-contained guest apps are not discovered by --deep; seal this bundle explicitly.
  codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/MacGuest/Serein Computer.app"
  # Nested code first, then the app again on its own with Serein's entitlements: --deep would
  # sign it without them, and the built-in computer needs com.apple.security.virtualization.
  codesign --force --deep --sign "${IDENTITY:--}" "$APP"
  codesign --force --entitlements scripts/Serein.entitlements --sign "${IDENTITY:--}" "$APP"
  codesign --verify --deep --strict "$APP"
fi
# ditto keeps the framework symlinks Python's zip drops, and leaves out the metadata a
# cloud-backed folder can add back.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$DIST_DIR/Serein-Free-macOS-$ARCH.zip"
# Replace the old app, do not merge into it: ditto keeps a file that only the old build had, and
# such a file breaks the seal of the new signature. The check is on the copy that people open.
rm -rf "$DIST_DIR/Serein.app"
ditto "$APP" "$DIST_DIR/Serein.app"
codesign --verify --deep "$DIST_DIR/Serein.app"
printf 'Built %s/Serein.app and %s/Serein-Free-macOS-%s.zip\n' "$DIST_DIR" "$DIST_DIR" "$ARCH"
