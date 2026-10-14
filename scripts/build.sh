#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
build_root="$project_root/build"
app_path="$build_root/朝夕.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/usr/bin/swiftc -parse-as-library -O -target arm64-apple-macos15.0 "$project_root"/Sources/*.swift -o "$app_path/Contents/MacOS/Chaoxi" -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>朝夕</string>
<key>CFBundleDisplayName</key><string>朝夕</string>
<key>CFBundleIdentifier</key><string>com.djx.chaoxi</string>
<key>CFBundleExecutable</key><string>Chaoxi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>朝夕捕获</string><key>CFBundleURLSchemes</key><array><string>chaoxi</string></array><key>CFBundleTypeRole</key><string>Viewer</string></dict></array>
</dict></plist>
PLIST
/usr/bin/swift "$project_root/scripts/icon.swift" "$build_root"
/usr/bin/iconutil -c icns "$build_root/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
/usr/bin/python3 "$project_root/scripts/sound.py" "$app_path/Contents/Resources/soft.wav"
cp "$project_root/Resources/Maccy-LICENSE.txt" "$app_path/Contents/Resources/Maccy-LICENSE.txt"
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
print -r -- "$app_path"
