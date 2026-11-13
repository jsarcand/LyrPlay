#!/bin/bash
# Builds TailscaleKit.xcframework from the libtailscale submodule and copies
# it to Frameworks/. The binary is not committed: it needs Go and full Xcode.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
swift_dir="$root/ThirdParty/libtailscale/swift"
product="$swift_dir/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
destination="$root/Frameworks/TailscaleKit.xcframework"

if ! command -v go >/dev/null 2>&1; then
    echo "Go is not installed. Install it from https://go.dev/dl/ and run this script again." >&2
    exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild failed. Point the active developer directory at full Xcode:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

if [[ ! -f "$swift_dir/Makefile" ]]; then
    echo "Missing $swift_dir. Run: git submodule update --init ThirdParty/libtailscale" >&2
    exit 1
fi

make -C "$swift_dir" ios-fat

if [[ ! -d "$product" ]]; then
    echo "The build finished without $product." >&2
    exit 1
fi

rm -rf "$destination"
mkdir -p "$root/Frameworks"
cp -R "$product" "$destination"

cat <<'EOF'

Copied Frameworks/TailscaleKit.xcframework.

In Xcode, select the iOS LyrPlay target → General → Frameworks, Libraries,
and Embedded Content. Add TailscaleKit.xcframework and set it to Embed & Sign.
Until that framework is linked, the app stays on the normal connection and
shows "Tailscale isn't in this build" when a remote path is needed.

Before an App Store archive, the Go runtime inside this library uses
file-timestamp and system-boot-time APIs. Add Apple's required-reason codes
for those categories to PrivacyInfo.xcprivacy. The codes are in Apple's
privacy-manifest documentation:
https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api
This script does not choose a code.
EOF
