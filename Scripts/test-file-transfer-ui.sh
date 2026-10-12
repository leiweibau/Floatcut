#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/FloatcutV3UITests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -module-cache-path "$test_directory/module-cache" \
    Sync/FloatcutFileTransferModel.swift FloatcutTransferWindowController.swift \
    Tests/FileTransferUITests/CoordinatorStub.swift Tests/FileTransferUITests/main.swift \
    -o "$test_directory/file-transfer-ui-tests"
"$test_directory/file-transfer-ui-tests"
