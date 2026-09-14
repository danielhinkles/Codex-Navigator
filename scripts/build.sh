#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --scratch-path .build -c release -debug-info-format none
installed_app="$PWD/dist/Codex Navigator.app"
package_root="$(mktemp -d "$PWD/.build/navigator-package.XXXXXX")"
app="$package_root/Codex Navigator.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/backend"
cp .build/release/CodexNavigator "$app/Contents/MacOS/CodexNavigator"
cp -R Sources/Navigator/Resources/PurpleSurge "$app/Contents/Resources/PurpleSurge"
cp backend/*.py "$app/Contents/Resources/backend/"
cp codex-navigator-mockup.png "$app/Contents/Resources/demo-preview.png"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexNavigator</string>
<key>CFBundleIdentifier</key><string>local.navigator.codex</string>
<key>CFBundleName</key><string>Codex Navigator</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Use your microphone when you start dictation or voice chat. Voice chat sends audio to Codex.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn speech into a prompt when you choose Dictate. Speech recognition is provided by macOS.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>Read local files to show previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.</string>
<key>NSDesktopFolderUsageDescription</key><string>Read local files to show previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Read local files to show previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Read local files to show previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Read local files to show previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.</string>
<key>NSAppDataUsageDescription</key><string>Read local files to show previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
# Never truncate a running, signed executable. Keep the previous bundle intact
# while installing the fully built and signed replacement on the same volume.
mkdir -p "$PWD/dist"
if [[ -d "$installed_app" ]]; then
    mv "$installed_app" "$package_root/Previous Codex Navigator.app"
fi
if ! mv "$app" "$installed_app"; then
    if [[ -d "$package_root/Previous Codex Navigator.app" ]]; then
        mv "$package_root/Previous Codex Navigator.app" "$installed_app"
    fi
    exit 1
fi
echo "Built $installed_app"
