#!/bin/bash
# Builds Mactivity into a macOS .app bundle.
#
#   ./build_app.sh              build the bundle in this directory
#   ./build_app.sh --install    build, install into /Applications, relaunch
#
# Environment overrides:
#   SIGN_IDENTITY  codesign identity; "-" (default) is an ad-hoc signature
#   UNIVERSAL      1 to build a universal arm64 + x86_64 binary
#   HARDENED       1 to enable the hardened runtime (required to notarize)
#   INSTALL_DIR    install target for --install (default /Applications)
#   ICON_SRC       source PNG for the app icon (default Assets/AppIcon.png)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MactivityMonitor"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${BUILD:-$(echo "$VERSION" | tr -d '.')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-0}"
HARDENED="${HARDENED:-0}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

DO_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        *) echo "usage: $0 [--install]" >&2; exit 2 ;;
    esac
done

# Building for both architectures goes through xcbuild, which ships with Xcode
# rather than the Command Line Tools.
BUILD_FLAGS=(-c release)
if [ "$UNIVERSAL" = "1" ]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
    if [ ! -x "$(xcode-select -p)/usr/bin/xcodebuild" ] && [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi

echo "Building ${APP_NAME} ${VERSION} (build ${BUILD})..."
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
EXECUTABLE_PATH="${BIN_PATH}/${APP_NAME}"

if [ ! -f "${EXECUTABLE_PATH}" ]; then
    echo "error: built executable not found at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

echo "Creating app bundle..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# A running instance holds the old binary open, which makes the copy fail.
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "Quitting running instance..."
    pkill -x "${APP_NAME}" || true
    for _ in 1 2 3 4 5; do
        pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.bpmsupreme.${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>Mactivity</string>
    <key>CFBundleDisplayName</key>
    <string>Mactivity Monitor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Sascha Nowlin. MIT licensed.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Mactivity needs to run the system purge command to free inactive memory.</string>
</dict>
</plist>
EOF

# Override the source with: ICON_SRC=/path/to/icon.png ./build_app.sh
ICON_SRC="${ICON_SRC:-Assets/AppIcon.png}"
if [ -f "$ICON_SRC" ]; then
    echo "Building app icon from ${ICON_SRC}..."
    ICON_TMP="$(mktemp -d)"
    ICONSET="${ICON_TMP}/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
        set -- $spec
        sips -s format png -z "$1" "$1" "$ICON_SRC" --out "$ICONSET/$2.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "${RESOURCES_DIR}/AppIcon.icns"
    rm -rf "$ICON_TMP"
elif [ -f "${RESOURCES_DIR}/AppIcon.icns" ]; then
    echo "No icon source at ${ICON_SRC}; keeping existing AppIcon.icns."
else
    echo "warning: no icon source and no existing AppIcon.icns; the bundle will use the generic icon." >&2
fi

# Signing gives the bundle a stable identity across rebuilds, which Launch at
# Login and the TCC prompts both rely on. An ad-hoc signature ("-") is enough
# for local use; a release is signed with a Developer ID and the hardened
# runtime so it can be notarized.
CODESIGN_FLAGS=(--force --sign "${SIGN_IDENTITY}")
if [ "$HARDENED" = "1" ]; then
    CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
if [ "${SIGN_IDENTITY}" = "-" ]; then
    echo "Signing (ad-hoc)..."
else
    echo "Signing as ${SIGN_IDENTITY}..."
fi
codesign "${CODESIGN_FLAGS[@]}" "${APP_BUNDLE}"
codesign --verify --strict "${APP_BUNDLE}"

# Refresh Launch Services so the new Info.plist is picked up.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${APP_BUNDLE}" 2>/dev/null || true

# Only files *inside* Contents/ get rewritten, so the .app directory entry keeps
# its original mtime and Finder reports a stale "Date Modified". Bump it.
touch "${APP_BUNDLE}"

echo "App bundle created at ${APP_BUNDLE}"

if [ "$DO_INSTALL" -ne 1 ]; then
    echo
    echo "Not installed. Run './build_app.sh --install' to install into ${INSTALL_DIR}."
    echo "Launch at Login only works from ${INSTALL_DIR}, so an uninstalled build"
    echo "will leave any copy already there running the old code."
    exit 0
fi

TARGET="${INSTALL_DIR}/${APP_BUNDLE}"
echo "Installing to ${TARGET}..."

if [ ! -w "${INSTALL_DIR}" ]; then
    echo "error: ${INSTALL_DIR} is not writable; re-run with sudo or set INSTALL_DIR=." >&2
    exit 1
fi

# Remove the old bundle rather than copying over it, so files dropped from the
# build do not linger and invalidate the signature.
rm -rf "${TARGET}"
# ditto, not cp: it preserves the bundle metadata the code signature covers.
ditto "${APP_BUNDLE}" "${TARGET}"
# ditto preserves timestamps, including the bundle directory's.
touch "${TARGET}"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${TARGET}" 2>/dev/null || true

codesign --verify --strict "${TARGET}" && echo "Signature OK."

echo "Launching ${TARGET}..."
open "${TARGET}"
echo "Installed."
