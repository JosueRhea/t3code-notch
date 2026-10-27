#!/bin/zsh
# Builds T3Notch.app (agent app: no Dock icon, no menu bar).
#   SIGN_IDENTITY=<sha1 or name>  sign with a specific certificate (default: first "Apple Development")
set -e
cd "$(dirname "$0")"
swift build -c release
APP=T3Notch.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/T3Notch $APP/Contents/MacOS/T3Notch
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp -R Resources/Logos $APP/Contents/Resources/Logos
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T3 Notch</string>
  <key>CFBundleDisplayName</key><string>T3 Notch</string>
  <key>CFBundleIdentifier</key><string>dev.custom-dock.t3notch</string>
  <key>CFBundleExecutable</key><string>T3Notch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# A stable identity keeps macOS's trust (Launch at Login, Keychain) across rebuilds;
# ad-hoc signatures change every build. Names can be ambiguous, so pick by SHA-1.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"Apple Development/ { print $2; exit }')}
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" $APP >/dev/null
  echo "Signed with $(codesign -dvv $APP 2>&1 | awk -F= '/^Authority/ { print $2; exit }')"
else
  codesign --force --sign - $APP >/dev/null
  echo "No signing certificate found; signed ad-hoc"
fi
echo "Built $PWD/$APP"
