#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/build"
APP="$OUT/Clipbook.app"
DEST="$HOME/Applications/Clipbook.app"
PLIST="$HOME/Library/LaunchAgents/com.schnappi.clipbook.plist"
UIDN="$(id -u)"
LOGDIR="$HOME/Library/Logs/Clipbook"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "self-test binary"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
swiftc -swift-version 5 -O -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -framework ApplicationServices \
  -framework CryptoKit \
  -lsqlite3 \
  -parse-as-library \
  -o "$OUT/Clipbook" \
  "$ROOT"/Sources/Clipbook/*.swift

"$OUT/Clipbook" --self-test

echo "icon"
swiftc -swift-version 5 -O -sdk "$SDK" -framework AppKit -o "$OUT/makeicon" "$ROOT/scripts/makeicon.swift"
"$OUT/makeicon" "$OUT/icon-1024.png"
ICONSET="$OUT/icon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$OUT/icon-1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$OUT/icon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$OUT/icon-1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$OUT/icon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$OUT/icon-1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$OUT/icon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$OUT/icon-1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$OUT/icon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$OUT/icon-1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$OUT/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

echo "bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Clipbook" "$APP/Contents/MacOS/Clipbook"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Clipbook Local\)"/\1/p' | head -1)"
if [[ -z "$SIGN_ID" ]]; then
  echo "creating a stable local signing identity" >&2
  "$ROOT/scripts/ensure-signing-identity.sh"
  SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Clipbook Local\)"/\1/p' | head -1)"
fi
if [[ -z "$SIGN_ID" ]]; then
  echo "no stable signing identity; using an ad-hoc signature" >&2
  SIGN_ID="-"
fi
echo "sign $SIGN_ID"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - --identifier com.schnappi.clipbook "$APP"
else
  # Same certificate on every build, so the Settings switch survives an update.
  codesign --force --sign "$SIGN_ID" --identifier com.schnappi.clipbook \
    --requirements '=designated => identifier "com.schnappi.clipbook" and certificate leaf[subject.CN] = "Clipbook Local"' \
    "$APP"
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$LOGDIR"
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" || true
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - --identifier com.schnappi.clipbook "$DEST"
else
  codesign --force --sign "$SIGN_ID" --identifier com.schnappi.clipbook \
    --requirements '=designated => identifier "com.schnappi.clipbook" and certificate leaf[subject.CN] = "Clipbook Local"' \
    "$DEST"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.schnappi.clipbook</string>
  <key>ProgramArguments</key>
  <array>
    <string>${DEST}/Contents/MacOS/Clipbook</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>com.schnappi.clipbook</string>
  </array>
  <key>StandardOutPath</key>
  <string>${LOGDIR}/clipbook.log</string>
  <key>StandardErrorPath</key>
  <string>${LOGDIR}/clipbook.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/${UIDN}/com.schnappi.clipbook" 2>/dev/null || true
pkill -x Clipbook 2>/dev/null || true
sleep 0.4
launchctl bootstrap "gui/${UIDN}" "$PLIST"
launchctl enable "gui/${UIDN}/com.schnappi.clipbook" || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DEST" >/dev/null

sleep 0.8
if ! pgrep -x Clipbook >/dev/null; then
  echo "Clipbook did not stay running" >&2
  tail -80 "$LOGDIR/clipbook.log" >&2 || true
  exit 1
fi

echo "Installed $DEST"
