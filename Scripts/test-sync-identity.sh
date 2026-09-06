#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutSyncIdentityTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
xcrun swiftc \
  Sync/FloatcutSyncProtocol.swift \
  Sync/FloatcutSyncIdentity.swift \
  Tests/SyncIdentityTests/main.swift \
  -o "${BUILD_DIR}/FloatcutSyncIdentityTests"
PERSISTENCE_SUITE="de.meierkarsten.floatcut.sync-restart-test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup_persistence_test() {
  "${BUILD_DIR}/FloatcutSyncIdentityTests" --persistence-cleanup "${PERSISTENCE_SUITE}" >/dev/null 2>&1 || true
}
trap cleanup_persistence_test EXIT
"${BUILD_DIR}/FloatcutSyncIdentityTests" --persistence-create "${PERSISTENCE_SUITE}"
"${BUILD_DIR}/FloatcutSyncIdentityTests" --persistence-reload "${PERSISTENCE_SUITE}"
"${BUILD_DIR}/FloatcutSyncIdentityTests"
