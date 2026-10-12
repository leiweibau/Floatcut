#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="/private/tmp/FloatcutSyncFileTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc -target "$(uname -m)-apple-macosx13.5" \
  Sync/FloatcutSyncProtocol.swift Sync/FloatcutSyncLifecycle.swift \
  Sync/FloatcutFileTransferModel.swift Sync/FloatcutFileStorage.swift \
  Sync/FloatcutFileTransferJournal.swift Sync/FloatcutFileDataConnection.swift \
  Sync/FloatcutFileTransferEngine.swift Tests/SyncFileTests/main.swift \
  -o "${BUILD_DIR}/FloatcutSyncFileTests"
"${BUILD_DIR}/FloatcutSyncFileTests" "${ROOT_DIR}/../Floatcut-SRC/docs/Protocol/fixtures/v3"
