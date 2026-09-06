#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/FloatcutStoragePerformanceTests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"
clang -O2 -fblocks -fobjc-exceptions -DFLOATCUT_PERFORMANCE_TESTING=1 \
  -Wno-nullability-completeness -framework Cocoa -I FloatcutEngine -I . \
  -include Floatcut_Prefix.pch FloatcutEngine/FloatcutClipping.m \
  FloatcutEngine/FloatcutStore.m FloatcutOperator.m Tests/StoragePerformanceTests.m \
  -o "${BUILD_DIR}/FloatcutStoragePerformanceTests"
"${BUILD_DIR}/FloatcutStoragePerformanceTests"
