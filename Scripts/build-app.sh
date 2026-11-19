#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Build on an Apple silicon Mac using an arm64 shell." >&2
    exit 1
fi

configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "Use debug or release." >&2; exit 2;; esac

scratch="$PWD/.build/videotran"
export CLANG_MODULE_CACHE_PATH="$scratch/clang"
swift_flags=(--scratch-path "$scratch" --manifest-cache local --cache-path "$scratch/cache"
             --config-path "$scratch/config" --security-path "$scratch/security")
if [[ "${VIDEO_SUBTITLE_NESTED_SANDBOX:-0}" == "1" ]]; then
    swift_flags+=(--disable-sandbox)
fi

swift build "${swift_flags[@]}" -c "$configuration" --product VideoTran
bin="$(swift build "${swift_flags[@]}" -c "$configuration" --show-bin-path)"
mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/VideoTran.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$bin/VideoTran" "$app/Contents/MacOS/VideoTran"
install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

(
    cd Plugin/VideoTran.iinaplugin
    /usr/bin/zip -q "$stage/VideoTran.iinaplgz" Info.json main.js
)
ditto "$app" "$PWD/dist/VideoTran.app"
install -m 644 "$stage/VideoTran.iinaplgz" dist/VideoTran.iinaplgz
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
dmg="VideoTran-${version}-macOS-arm64.dmg"
mkdir "$stage/image"
ditto "$app" "$stage/image/VideoTran.app"
ln -s /Applications "$stage/image/Applications"
/usr/bin/hdiutil create -volname VideoTran -srcfolder "$stage/image" -format UDZO "$stage/$dmg"
/usr/bin/hdiutil verify "$stage/$dmg"
install -m 644 "$stage/$dmg" "dist/$dmg"
echo "DMG: $PWD/dist/$dmg"
echo "App: $PWD/dist/VideoTran.app"
echo "IINA plugin: $PWD/dist/VideoTran.iinaplgz"
