#!/bin/zsh
# Builds the spike, wraps the binary in a menu-bar-only .app bundle, and launches it.
set -euo pipefail
cd "${0:A:h}"

swift build -c debug
app=.build/Soroband.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp .build/debug/Soroband $app/Contents/MacOS/Soroband
cat > $app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.abouleinein.soroband.spike</string>
    <key>CFBundleName</key><string>Soroband</string>
    <key>CFBundleExecutable</key><string>Soroband</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
open $app
