#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP="ChargeLimit.app"
BIN="$APP/Contents/MacOS/ChargeLimit"
PLIST="$APP/Contents/Info.plist"

# Build the binary into the app bundle if the source is newer (or bundle missing).
if [ ! -f "$BIN" ] || [ ChargeLimit.swift -nt "$BIN" ]; then
    mkdir -p "$APP/Contents/MacOS"
    swiftc ChargeLimit.swift -o "$BIN" -framework AppKit -framework SwiftUI
fi

# Minimal Info.plist so macOS treats this as a real app (grantable for automation,
# proper identity in Activity Monitor, LSUIElement so no Dock icon).
if [ ! -f "$PLIST" ] || [ "$0" -nt "$PLIST" ]; then
    cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ChargeLimit</string>
    <key>CFBundleIdentifier</key><string>net.quittnet.ChargeLimit</string>
    <key>CFBundleName</key><string>ChargeLimit</string>
    <key>CFBundleDisplayName</key><string>ChargeLimit</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
fi

pkill -f "$DIR/$BIN" 2>/dev/null || true
sleep 0.5
nohup "$DIR/$BIN" > "$DIR/ChargeLimit.log" 2>&1 &
echo "ChargeLimit launched (pid $!)"
