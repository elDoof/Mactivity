#!/bin/bash
# Produces the signed, notarized release artifacts in dist/.
#
#   ./release.sh
#
# Requires a Developer ID Application certificate in the keychain and a stored
# notarytool credential profile. Create the profile once with:
#
#   xcrun notarytool store-credentials "mactivity-notary" \
#       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Environment overrides:
#   SIGN_IDENTITY   codesign identity (default: the first Developer ID Application)
#   NOTARY_PROFILE  notarytool keychain profile name (default mactivity-notary)
#   SKIP_NOTARIZE   1 to sign and package without submitting to Apple
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MactivityMonitor"
APP_BUNDLE="${APP_NAME}.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
DIST="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-mactivity-notary}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

ZIP_NAME="Mactivity-${VERSION}.zip"
DMG_NAME="Mactivity-${VERSION}.dmg"

# Resolve the signing identity. Notarization requires a Developer ID; an ad-hoc
# signature is rejected, so fail early rather than after a long build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "${SIGN_IDENTITY}" ]; then
    echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
    echo "       Install one from developer.apple.com, or set SIGN_IDENTITY." >&2
    exit 1
fi

if [ "${SKIP_NOTARIZE}" != "1" ]; then
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        echo "error: no notarytool credentials stored under profile '${NOTARY_PROFILE}'." >&2
        echo "       Create them with 'xcrun notarytool store-credentials', or set" >&2
        echo "       SKIP_NOTARIZE=1 to build signed-but-unnotarized artifacts." >&2
        exit 1
    fi
fi

echo "==> Releasing Mactivity ${VERSION}"
echo "    identity: ${SIGN_IDENTITY}"

rm -rf "${DIST}"
mkdir -p "${DIST}"

# 1. Universal, hardened, Developer ID-signed bundle.
UNIVERSAL=1 HARDENED=1 SIGN_IDENTITY="${SIGN_IDENTITY}" ./build_app.sh

echo "==> Verifying signature"
codesign --verify --strict --deep --verbose=2 "${APP_BUNDLE}"
# A hardened runtime is what makes the bundle eligible for notarization.
# Captured rather than piped into grep: grep -q closes the pipe on its first
# match, codesign then dies of SIGPIPE, and pipefail fails the whole pipeline
# even though the match succeeded.
SIGNATURE_INFO="$(codesign -d --verbose=2 "${APP_BUNDLE}" 2>&1)"
case "${SIGNATURE_INFO}" in
    *"(runtime)"*) echo "    hardened runtime: yes" ;;
    *) echo "error: hardened runtime flag missing from the signature." >&2; exit 1 ;;
esac

if [ "${SKIP_NOTARIZE}" != "1" ]; then
    # 2. Notarize the app, then staple the ticket into the bundle so Gatekeeper
    #    can validate it without a network round trip.
    echo "==> Submitting the app for notarization (this usually takes a few minutes)"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${DIST}/notarize-app.zip"
    xcrun notarytool submit "${DIST}/notarize-app.zip" \
        --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP_BUNDLE}"
    rm -f "${DIST}/notarize-app.zip"
fi

# 3. Zip archive of the finished bundle.
echo "==> Building ${ZIP_NAME}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${DIST}/${ZIP_NAME}"

# 4. Disk image, with the customary drag-to-Applications layout.
echo "==> Building ${DMG_NAME}"
STAGE="$(mktemp -d)"
ditto "${APP_BUNDLE}" "${STAGE}/${APP_BUNDLE}"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -quiet -volname "Mactivity ${VERSION}" -srcfolder "${STAGE}" \
    -ov -format UDZO "${DIST}/${DMG_NAME}"
rm -rf "${STAGE}"

# The disk image is a separate artifact and needs its own signature and ticket,
# otherwise Gatekeeper flags the download itself even though the app inside is
# notarized.
codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DIST}/${DMG_NAME}"
if [ "${SKIP_NOTARIZE}" != "1" ]; then
    echo "==> Submitting the disk image for notarization"
    xcrun notarytool submit "${DIST}/${DMG_NAME}" \
        --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${DIST}/${DMG_NAME}"
fi

# 5. Checksums, so a download can be verified.
echo "==> Writing checksums"
( cd "${DIST}" && shasum -a 256 "${ZIP_NAME}" "${DMG_NAME}" > SHA256SUMS.txt )

echo
echo "==> Verification"
if [ "${SKIP_NOTARIZE}" != "1" ]; then
    xcrun stapler validate "${APP_BUNDLE}"
    xcrun stapler validate "${DIST}/${DMG_NAME}"
fi
# The assessment Gatekeeper itself performs on a downloaded app.
spctl --assess --type execute --verbose=2 "${APP_BUNDLE}" || true

echo
echo "Artifacts in ${DIST}/:"
ls -lh "${DIST}"
cat "${DIST}/SHA256SUMS.txt"
