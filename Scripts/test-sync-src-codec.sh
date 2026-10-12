#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncV3ContractTests"
SRC_ROOT="${FLOATCUT_SRC_ROOT:-${ROOT_DIR}/../Floatcut-SRC}"
V3_PYTHON="${FLOATCUT_V3_PYTHON:-python3}"
if [[ -z "${FLOATCUT_V3_PYTHON:-}" && -x "${SRC_ROOT}/.venv/bin/python" ]]; then
  V3_PYTHON="${SRC_ROOT}/.venv/bin/python"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
"${V3_PYTHON}" -c 'import pytest, jsonschema, referencing' || {
  echo "V3 contract checks require pytest/jsonschema. Set FLOATCUT_V3_PYTHON to an interpreter containing those development dependencies." >&2
  exit 1
}
xcrun swiftc -O Sync/FloatcutSyncProtocol.swift Tests/SyncInteropTests/main.swift \
  -o "${BUILD_DIR}/FloatcutSyncV3ContractTests"
ARTIFACT_DIR="$(mktemp -d "${BUILD_DIR}/artifacts.XXXXXX")"
"${BUILD_DIR}/FloatcutSyncV3ContractTests" "${SRC_ROOT}/docs/Protocol/fixtures/v3" "${ARTIFACT_DIR}"
"${V3_PYTHON}" -B Tests/SyncInteropTests/verify_src.py "${SRC_ROOT}" "${ARTIFACT_DIR}"
echo "V3 contract artifacts verified; this is not native Python/Windows/macOS LAN interoperability."
echo "Synthetic test artifacts: ${ARTIFACT_DIR}"
