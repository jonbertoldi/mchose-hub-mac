#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=MchoseHub.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
swiftc -O -parse-as-library main.swift DSP.swift Processor.swift EQView.swift -o $APP/Contents/MacOS/MchoseHub
mkdir -p $APP/Contents/Resources && cp Presets.json hrir48.bin $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MchoseHub</string>
<key>CFBundleIdentifier</key><string>local.mchose.hub</string>
<key>CFBundleName</key><string>MchoseHub</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>MchoseHub processes system audio for EQ and virtual surround.</string>
<key>NSMicrophoneUsageDescription</key><string>Needed by the headset audio device that MchoseHub routes sound to.</string>
<key>NSHumanReadableCopyright</key><string>Unofficial</string>
</dict></plist>
P
codesign --force --sign - $APP
echo built $APP
