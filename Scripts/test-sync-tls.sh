#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncTLSTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc \
  Sync/FloatcutSyncProtocol.swift \
  Sync/FloatcutSyncIdentity.swift \
  Tests/SyncTLSTests/main.swift \
  -framework Network \
  -framework Security \
  -o "${BUILD_DIR}/FloatcutSyncTLSTests"
"${BUILD_DIR}/FloatcutSyncTLSTests"
