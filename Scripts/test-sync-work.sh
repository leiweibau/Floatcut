#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncWorkTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc -O Sync/FloatcutSyncProtocol.swift Sync/FloatcutSyncWork.swift \
  FloatcutThumbnailService.swift Tests/SyncWorkTests/main.swift \
  -o "${BUILD_DIR}/FloatcutSyncWorkTests"
"${BUILD_DIR}/FloatcutSyncWorkTests"
