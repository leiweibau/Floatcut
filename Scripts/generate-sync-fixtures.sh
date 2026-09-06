#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALID_JSON="${ROOT_DIR}/docs/Protocol/fixtures/valid/clipboard-update.json"
VALID_FRAME="${ROOT_DIR}/docs/Protocol/fixtures/valid/clipboard-update.frame"
INVALID_ZERO="${ROOT_DIR}/docs/Protocol/fixtures/invalid/zero-length.frame"
INVALID_LARGE="${ROOT_DIR}/docs/Protocol/fixtures/invalid/oversized-length.frame"
INVALID_DIR="${ROOT_DIR}/docs/Protocol/fixtures/invalid"

frame_payload_file() {
  local payload_path="$1"
  local frame_path="$2"
  local size
  size="$(wc -c < "${payload_path}" | tr -d ' ')"
  printf '%08x' "${size}" | xxd -r -p > "${frame_path}"
  /bin/cat "${payload_path}" >> "${frame_path}"
}

payload_size="$(wc -c < "${VALID_JSON}" | tr -d ' ')"
if [[ "${payload_size}" != "403" ]]; then
  echo "Unexpected clipboard fixture length: ${payload_size}" >&2
  exit 1
fi

{
  printf '\x00\x00\x01\x93'
  /bin/cat "${VALID_JSON}"
} > "${VALID_FRAME}"
printf '\x00\x00\x00\x00' > "${INVALID_ZERO}"
printf '\x00\x10\x00\x01' > "${INVALID_LARGE}"
printf '\x00\x00' > "${INVALID_DIR}/truncated-prefix.frame"
printf '\x00\x00\x00\x05{}' > "${INVALID_DIR}/truncated-payload.frame"
printf '\x00\x00\x00\x02\xc3\x28' > "${INVALID_DIR}/invalid-utf8.frame"
frame_payload_file "${INVALID_DIR}/duplicate-key.json" "${INVALID_DIR}/duplicate-key.frame"
frame_payload_file "${INVALID_DIR}/nesting-depth-9.json" "${INVALID_DIR}/nesting-depth-9.frame"
frame_payload_file "${INVALID_DIR}/incompatible-version.json" "${INVALID_DIR}/incompatible-version.frame"
frame_payload_file "${INVALID_DIR}/invalid-hash.json" "${INVALID_DIR}/invalid-hash.frame"

echo "Generated Floatcut Sync protocol fixtures"
