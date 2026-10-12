#!/bin/bash

# Build a Developer ID-signed, notarized and stapled app and disk image.
# This deliberately has no local/ad-hoc signing fallback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -z "${FLOATCUT_NOTARY_PROFILE:-}" ]]; then
  echo "Set FLOATCUT_NOTARY_PROFILE to a notarytool Keychain profile." >&2
  exit 1
fi

NOTARY_ARGS=(--keychain-profile "${FLOATCUT_NOTARY_PROFILE}")
if [[ -n "${FLOATCUT_NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_ARGS+=(--keychain "${FLOATCUT_NOTARY_KEYCHAIN}")
fi

VALID_IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ -n "${FLOATCUT_DEVELOPER_ID_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="${FLOATCUT_DEVELOPER_ID_IDENTITY}"
  if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]] ||
     ! /usr/bin/grep -Fq "\"${SIGNING_IDENTITY}\"" <<< "${VALID_IDENTITIES}"; then
    echo "The requested Developer ID Application identity is not available for code signing." >&2
    exit 1
  fi
else
  IDENTITY_COUNT="$(/usr/bin/awk -F '"' '/"Developer ID Application:/{count++} END {print count+0}' <<< "${VALID_IDENTITIES}")"
  if [[ "${IDENTITY_COUNT}" -ne 1 ]]; then
    echo "Expected exactly one valid Developer ID Application identity; found ${IDENTITY_COUNT}." >&2
    echo "Import the certificate and private key, or set FLOATCUT_DEVELOPER_ID_IDENTITY." >&2
    exit 1
  fi
  SIGNING_IDENTITY="$(/usr/bin/awk -F '"' '/"Developer ID Application:/{print $2; exit}' <<< "${VALID_IDENTITIES}")"
fi

if [[ ! "${SIGNING_IDENTITY}" =~ \(([A-Z0-9]{10})\)$ ]]; then
  echo "Could not determine the Team ID from the Developer ID identity." >&2
  exit 1
fi
TEAM_ID="${BASH_REMATCH[1]}"

if ! xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json >/dev/null; then
  echo "The notarytool profile is unavailable or cannot authenticate." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/floatcut-notarized.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
APP_PATH="${WORK_DIR}/DerivedData/Build/Products/Release/Floatcut.app"
STAGED_APP="${WORK_DIR}/Floatcut.app"
STAGED_DMG="${WORK_DIR}/Floatcut.dmg"

submit_and_check() {
  local archive_path="$1"
  local response_path="$2"
  local submission_id status

  if ! xcrun notarytool submit "${archive_path}" "${NOTARY_ARGS[@]}" \
    --wait --timeout 45m --output-format json > "${response_path}"; then
    if submission_id="$(plutil -extract id raw -o - "${response_path}" 2>/dev/null)"; then
      xcrun notarytool log "${submission_id}" "${NOTARY_ARGS[@]}" || true
    fi
    echo "Notarization submission failed for ${archive_path}; existing dist artifacts were not replaced." >&2
    exit 1
  fi
  submission_id="$(plutil -extract id raw -o - "${response_path}")"
  status="$(plutil -extract status raw -o - "${response_path}")"
  echo "Notarization ${submission_id}: ${status}"
  xcrun notarytool log "${submission_id}" "${NOTARY_ARGS[@]}"
  if [[ "${status}" != "Accepted" ]]; then
    echo "Notarization rejected ${archive_path}. Existing dist artifacts were not replaced." >&2
    exit 1
  fi
}

echo "Building Floatcut for Developer ID distribution"
xcodebuild \
  -project "${ROOT_DIR}/Floatcut.xcodeproj" \
  -scheme Floatcut \
  -configuration Release \
  -derivedDataPath "${WORK_DIR}/DerivedData" \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "The Release build did not produce Floatcut.app." >&2
  exit 1
fi

# Sign the app itself, not --deep: nested executable code must be signed
# separately before the containing app if it is added in the future.
if [[ -d "${APP_PATH}/Contents/Frameworks" || -d "${APP_PATH}/Contents/PlugIns" ||
      -d "${APP_PATH}/Contents/XPCServices" || -d "${APP_PATH}/Contents/Helpers" ]]; then
  echo "Nested code was found. Update this script to sign it inside-out." >&2
  exit 1
fi
codesign --force --options runtime --timestamp \
  --entitlements "${ROOT_DIR}/Floatcut.entitlements" \
  --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
if [[ "${SIGNATURE_DETAILS}" != *"Authority=Developer ID Application:"* ||
      "${SIGNATURE_DETAILS}" != *"TeamIdentifier=${TEAM_ID}"* ||
      "${SIGNATURE_DETAILS}" != *"runtime"* ||
      "${SIGNATURE_DETAILS}" != *"Timestamp="* ]]; then
  echo "Developer ID signature, Team ID, hardened runtime, or timestamp verification failed." >&2
  exit 1
fi

ARCHS="$(lipo -archs "${APP_PATH}/Contents/MacOS/Floatcut")"
if [[ " ${ARCHS} " != *" arm64 "* || " ${ARCHS} " != *" x86_64 "* ]]; then
  echo "The app is not a universal arm64/x86_64 binary: ${ARCHS}" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Invalid app version: ${VERSION}" >&2
  exit 1
fi
if [[ -n "${FLOATCUT_EXPECTED_VERSION:-}" && "${VERSION}" != "${FLOATCUT_EXPECTED_VERSION}" ]]; then
  echo "Release tag version ${FLOATCUT_EXPECTED_VERSION} does not match app version ${VERSION}." >&2
  exit 1
fi

ditto "${APP_PATH}" "${STAGED_APP}"
ditto -c -k --keepParent --rsrc "${STAGED_APP}" "${WORK_DIR}/Floatcut.zip"
submit_and_check "${WORK_DIR}/Floatcut.zip" "${WORK_DIR}/app-notary-result.json"
xcrun stapler staple "${STAGED_APP}"
xcrun stapler validate "${STAGED_APP}"
spctl --assess --type execute --verbose=4 "${STAGED_APP}"

mkdir -p "${WORK_DIR}/dmg-contents"
ditto "${STAGED_APP}" "${WORK_DIR}/dmg-contents/Floatcut.app"
ln -s /Applications "${WORK_DIR}/dmg-contents/Applications"
hdiutil create -volname Floatcut -srcfolder "${WORK_DIR}/dmg-contents" \
  -format UDZO "${STAGED_DMG}"
hdiutil verify "${STAGED_DMG}"
codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${STAGED_DMG}"
codesign --verify --verbose=2 "${STAGED_DMG}"
submit_and_check "${STAGED_DMG}" "${WORK_DIR}/dmg-notary-result.json"
xcrun stapler staple "${STAGED_DMG}"
xcrun stapler validate "${STAGED_DMG}"
spctl --assess --type open --context context:primary-signature --verbose=4 "${STAGED_DMG}"

mkdir -p "${DIST_DIR}"
DMG_NAME="Floatcut_universal_${VERSION}.dmg"
ditto "${STAGED_DMG}" "${DIST_DIR}/${DMG_NAME}.new"
if [[ -e "${DIST_DIR}/Floatcut.app" ]]; then
  mv "${DIST_DIR}/Floatcut.app" "${WORK_DIR}/previous-Floatcut.app"
fi
if ! ditto "${STAGED_APP}" "${DIST_DIR}/Floatcut.app"; then
  rm -rf -- "${DIST_DIR}/Floatcut.app"
  if [[ -d "${WORK_DIR}/previous-Floatcut.app" ]]; then
    mv "${WORK_DIR}/previous-Floatcut.app" "${DIST_DIR}/Floatcut.app"
  fi
  rm -f -- "${DIST_DIR}/${DMG_NAME}.new"
  exit 1
fi
mv -f "${DIST_DIR}/${DMG_NAME}.new" "${DIST_DIR}/${DMG_NAME}"
echo "Developer ID team: ${TEAM_ID}"
echo "Notarized app: ${DIST_DIR}/Floatcut.app"
echo "Notarized DMG: ${DIST_DIR}/${DMG_NAME}"
