#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/FloatcutPackageDerivedData}"
DIST_DIR="${ROOT_DIR}/dist"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/Floatcut.app"
LOCAL_SIGNING_IDENTITY="Floatcut Local Development"
SIGNING_IDENTITY="${FLOATCUT_SIGNING_IDENTITY:-}"

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -Fq "\"${LOCAL_SIGNING_IDENTITY}\""; then
    SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY}"
  else
    SIGNING_IDENTITY="-"
  fi
fi

sign_if_present() {
  local target_path="$1"
  local deep_flag="${2:-}"

  if [[ -e "${target_path}" ]]; then
    if [[ -n "${deep_flag}" ]]; then
      codesign --force --deep --timestamp=none --sign "${SIGNING_IDENTITY}" "${target_path}"
    else
      codesign --force --timestamp=none --sign "${SIGNING_IDENTITY}" "${target_path}"
    fi
  fi
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodebuild \
  -project "${ROOT_DIR}/Floatcut.xcodeproj" \
  -scheme Floatcut \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build

sign_if_present "${APP_PATH}" "deep"
echo "Codesigning identity: ${SIGNING_IDENTITY}"

rm -rf "${DIST_DIR}/Floatcut.app"
mkdir -p "${DIST_DIR}"
ditto "${APP_PATH}" "${DIST_DIR}/Floatcut.app"

lipo -info "${DIST_DIR}/Floatcut.app/Contents/MacOS/Floatcut"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${DIST_DIR}/Floatcut.app/Contents/Info.plist")"
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Invalid app version for DMG filename: ${VERSION}" >&2
  exit 1
fi
echo "App version: ${VERSION}"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${DIST_DIR}/Floatcut.app/Contents/Info.plist"

DMG_NAME="Floatcut_universal_${VERSION}.dmg"
DMG_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/floatcut-dmg.XXXXXX")"
trap 'if [[ -n "${DMG_TEMP_DIR:-}" && -d "${DMG_TEMP_DIR}" ]]; then rm -rf -- "${DMG_TEMP_DIR}"; fi' EXIT
mkdir -p "${DMG_TEMP_DIR}/contents"
ditto "${DIST_DIR}/Floatcut.app" "${DMG_TEMP_DIR}/contents/Floatcut.app"
ln -s /Applications "${DMG_TEMP_DIR}/contents/Applications"

hdiutil create \
  -volname "Floatcut" \
  -srcfolder "${DMG_TEMP_DIR}/contents" \
  -format UDZO \
  "${DMG_TEMP_DIR}/${DMG_NAME}"
hdiutil verify "${DMG_TEMP_DIR}/${DMG_NAME}"
mv -f "${DMG_TEMP_DIR}/${DMG_NAME}" "${DIST_DIR}/${DMG_NAME}"
echo "DMG: ${DIST_DIR}/${DMG_NAME}"
