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
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${DIST_DIR}/Floatcut.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${DIST_DIR}/Floatcut.app/Contents/Info.plist"
