#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/FloatcutV3CoordinatorTests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
module_cache="${TMPDIR:-/tmp}/FloatcutV3CoordinatorTests-module-cache"
mkdir -p "$module_cache"
xcrun swiftc -D FLOATCUT_SYNC_COORDINATOR_TESTS -module-cache-path "$module_cache" \
    Sync/FloatcutSyncProtocol.swift Sync/FloatcutSyncLifecycle.swift Sync/FloatcutSyncIdentity.swift \
    Sync/FloatcutSyncPairingV3.swift Sync/FloatcutSyncWork.swift Sync/FloatcutSyncCoordinator.swift \
    Sync/FloatcutFileTransferModel.swift Sync/FloatcutFileStorage.swift \
    Sync/FloatcutFileTransferJournal.swift Sync/FloatcutFileDataConnection.swift \
    Sync/FloatcutFileTransferEngine.swift Tests/SyncV3CoordinatorTests/main.swift \
    -framework AppKit -framework Network -framework Security -o "$test_directory/coordinator-tests"
"$test_directory/coordinator-tests"
