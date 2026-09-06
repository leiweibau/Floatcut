#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d /tmp/floatcut-engine-tests.XXXXXX)"
trap 'rm -rf "${TEST_BUILD_DIR}"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

clang \
  -fblocks \
  -fobjc-exceptions \
  -Wno-nullability-completeness \
  -framework Cocoa \
  -I "${PROJECT_DIR}/FloatcutEngine" \
  -I "${PROJECT_DIR}" \
  -include "${PROJECT_DIR}/Floatcut_Prefix.pch" \
  "${PROJECT_DIR}/FloatcutEngine/FloatcutClipping.m" \
  "${PROJECT_DIR}/FloatcutEngine/FloatcutStore.m" \
  "${PROJECT_DIR}/FloatcutOperator.m" \
  "${PROJECT_DIR}/Tests/FloatcutEngineRegressionTests.m" \
  -o "${TEST_BUILD_DIR}/FloatcutEngineRegressionTests"

"${TEST_BUILD_DIR}/FloatcutEngineRegressionTests"
