#!/bin/sh
# Builds AutoMixTap.app into the directory given as $1 (default: $TMPDIR/automix-lab).
# It is an app bundle so macOS asks for System Audio Recording permission for it by name.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${TMPDIR:-/tmp}/automix-lab}
app="$out/AutoMixTap.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/AutoMixTap" "$here/main.swift"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ensemble.automix-tap</string>
<key>CFBundleName</key><string>AutoMixTap</string>
<key>CFBundleExecutable</key><string>AutoMixTap</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Records Music's output to measure song transitions.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
echo "$app"
