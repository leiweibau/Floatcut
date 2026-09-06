#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncProtocolTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc \
  Sync/FloatcutSyncProtocol.swift \
  Tests/SyncProtocolTests/main.swift \
  -o "${BUILD_DIR}/FloatcutSyncProtocolTests"
"${BUILD_DIR}/FloatcutSyncProtocolTests"
