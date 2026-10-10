#!/usr/bin/env bash
# Builds SandSeek.app from this checkout.
#
#   Scripts/package_app.sh [output-directory]        (default: ./build)
#
# 1. builds the SandSeekApp executable in release mode,
# 2. puts it in an app bundle with an Info.plist,
# 3. copies the web sandbox's files into Contents/Resources/sandbox,
# 4. signs the bundle ad hoc (`codesign -s -`), which is enough to run it on
#    the Mac that built it.
#
# The sandbox files are copied by this script and not declared as SwiftPM
# resources on purpose: the app needs them as a plain folder that looks like a
# checkout (Scripts/research_sandbox.sh next to Sandbox/, because the script
# builds the image from ../Sandbox), so that it can hash that folder, copy it
# to ~/Library/Application Support/SandSeek/Sandbox and run the script from
# there. SwiftPM resources would arrive in a separate Bundle.module bundle with
# a layout and a lookup path of SwiftPM's choosing.
#
# Not done here: Sparkle updates and notarization.
set -euo pipefail

version="${SANDSEEK_VERSION:-0.1.0}"
bundle_id="io.github.osiriss664.sandseek"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "package_app.sh builds a macOS app and runs on macOS only." >&2
    exit 1
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$script_directory/.." && pwd)"
output="${1:-$root/build}"
app="$output/SandSeek.app"

for needed in "$root/Scripts/research_sandbox.sh" "$root/Sandbox/Containerfile"; do
    if [[ ! -f "$needed" ]]; then
        echo "Missing $needed; run this script from a complete SandSeek checkout." >&2
        exit 1
    fi
done

cd "$root"
echo "Building SandSeekApp (release)..."
swift build -c release --product SandSeekApp
bin_path="$(swift build -c release --show-bin-path)"
executable="$bin_path/SandSeekApp"
if [[ ! -x "$executable" ]]; then
    echo "The build did not produce $executable." >&2
    exit 1
fi

echo "Assembling $app ..."
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/sandbox/Scripts" "$app/Contents/Resources/sandbox/Sandbox"
cp "$executable" "$app/Contents/MacOS/SandSeek"

# The same layout as a checkout: the script finds its build context at ../Sandbox.
cp "$root/Scripts/research_sandbox.sh" "$app/Contents/Resources/sandbox/Scripts/research_sandbox.sh"
chmod 755 "$app/Contents/Resources/sandbox/Scripts/research_sandbox.sh"
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' \
    "$root/Sandbox/" "$app/Contents/Resources/sandbox/Sandbox/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SandSeek</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SandSeek</string>
    <key>CFBundleDisplayName</key>
    <string>SandSeek</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

echo "Signing ad hoc..."
codesign --force --deep -s - "$app"
codesign --verify --deep --strict "$app"

echo "Done: $app"
echo "Open it with:  open \"$app\""
