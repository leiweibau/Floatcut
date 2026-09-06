#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncInteropTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc -O Sync/FloatcutSyncProtocol.swift Sync/FloatcutSyncWork.swift \
  Tests/SyncInteropTests/main.swift -o "${BUILD_DIR}/FloatcutSyncInteropTests"
FIXTURE_DIR="$(mktemp -d "${BUILD_DIR}/fixtures.XXXXXX")"
"${BUILD_DIR}/FloatcutSyncInteropTests" emit "${FIXTURE_DIR}"
PYTHONPATH="${ROOT_DIR}/Floatcut-SRC/src" PYTHONDONTWRITEBYTECODE=1 \
  "${ROOT_DIR}/Floatcut-SRC/.venv/bin/python" Tests/SyncInteropTests/verify_src.py "${FIXTURE_DIR}"
"${BUILD_DIR}/FloatcutSyncInteropTests" verify "${FIXTURE_DIR}"
echo "Synthetic test artifacts: ${FIXTURE_DIR}"
