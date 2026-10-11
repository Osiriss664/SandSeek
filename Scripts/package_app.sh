#!/usr/bin/env bash
# Builds SandSeek.app from this checkout.
#
#   Scripts/package_app.sh [output-directory]    (default: <repo>/build)
#
# The output directory must be <repo>/build or a folder inside it, because the
# script deletes an earlier SandSeek.app there before it builds a new one.
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
# builds the image from ../Sandbox), so that it can run the script from
# Contents/Resources/sandbox in place: the folder is sealed by the bundle's
# signature, and the script and `container build` only read it. SwiftPM
# resources would arrive in a separate Bundle.module bundle with a layout and a
# lookup path of SwiftPM's choosing.
#
# Not done here: Sparkle updates and notarization.
set -euo pipefail

bundle_id="io.github.osiriss664.sandseek"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "package_app.sh builds a macOS app and runs on macOS only." >&2
    exit 1
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$script_directory/.." && pwd)"
# The default version is the one `sandseek --version` prints, from
# Sources/SandSeekCore/SandSeekVersion.swift; SANDSEEK_VERSION overrides it.
version="${SANDSEEK_VERSION:-$(sed -n 's/^ *public static let current = "\([^"]*\)".*/\1/p' "$root/Sources/SandSeekCore/SandSeekVersion.swift")}"
if [[ -z "$version" ]]; then
    echo "Could not read the version from Sources/SandSeekCore/SandSeekVersion.swift." >&2
    exit 1
fi
build_directory="$root/build"
# A relative output directory is relative to where the command was run.
requested="${1:-$build_directory}"
case "$requested" in
    /*) output="$requested" ;;
    *) output="$PWD/$requested" ;;
esac
output="${output%/}"
case "/$output/" in
    */../*|*/./*)
        echo "The output directory must not contain . or .. parts: $output" >&2
        exit 1
        ;;
esac
if [[ "$output" != "$build_directory" && "$output" != "$build_directory"/* ]]; then
    echo "The output directory must be $build_directory or a folder inside it: $output" >&2
    exit 1
fi
app="$output/SandSeek.app"

for needed in "$root/Scripts/research_sandbox.sh" "$root/Scripts/verify_sandbox_signature.py" \
        "$root/Sandbox/Containerfile"; do
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
# Only a SandSeek.app inside <repo>/build is ever removed.
if [[ "$app" != "$build_directory"/*"/SandSeek.app" && "$app" != "$build_directory/SandSeek.app" ]]; then
    echo "Refusing to remove $app" >&2
    exit 1
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/sandbox/Scripts" "$app/Contents/Resources/sandbox/Sandbox"
cp "$executable" "$app/Contents/MacOS/SandSeek"

# The same layout as a checkout: the script finds its build context at ../Sandbox.
cp "$root/Scripts/research_sandbox.sh" "$app/Contents/Resources/sandbox/Scripts/research_sandbox.sh"
chmod 755 "$app/Contents/Resources/sandbox/Scripts/research_sandbox.sh"
# selftest checks a signature with this script (it runs it with python3, from
# the script's own folder), so it must sit next to research_sandbox.sh.
cp "$root/Scripts/verify_sandbox_signature.py" "$app/Contents/Resources/sandbox/Scripts/verify_sandbox_signature.py"
chmod 644 "$app/Contents/Resources/sandbox/Scripts/verify_sandbox_signature.py"
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
