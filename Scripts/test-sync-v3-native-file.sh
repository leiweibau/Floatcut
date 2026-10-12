#!/bin/bash
set -euo pipefail
# FLOATCUT_V3_MAXIMUM_FILE_TEST=1 additionally transfers a real 8 GiB file.
# All sources, snapshots, and received test files use a unique temporary root.
cd "$(dirname "$0")/.."
build_directory="${TMPDIR:-/tmp}/FloatcutSyncV3NativeFileTests"
mkdir -p "$build_directory"
xcrun swiftc -O -module-cache-path "$build_directory/module-cache" \
    Sync/FloatcutSyncProtocol.swift Sync/FloatcutSyncLifecycle.swift Sync/FloatcutSyncIdentity.swift \
    Sync/FloatcutFileTransferModel.swift Sync/FloatcutFileStorage.swift \
    Sync/FloatcutFileTransferJournal.swift Sync/FloatcutFileDataConnection.swift \
    Sync/FloatcutFileTransferEngine.swift Tests/SyncV3NativeFileTests/main.swift \
    -framework Network -framework Security -o "$build_directory/native-file-tests"
"$build_directory/native-file-tests"
