#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncPerformanceTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc -O "${FLOATCUT_BENCHMARK_PROTOCOL_SOURCE:-Sync/FloatcutSyncProtocol.swift}" \
  Tests/SyncPerformanceTests/main.swift -o "${BUILD_DIR}/FloatcutSyncPerformanceTests"
"${BUILD_DIR}/FloatcutSyncPerformanceTests"
