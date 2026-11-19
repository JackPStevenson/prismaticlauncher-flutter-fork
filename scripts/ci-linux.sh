#!/usr/bin/env bash
# Linux validation entrypoint (Docker CMD and local use): format, analyze, test with coverage.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/flutter-env.sh

flutter pub get
./scripts/format-check.sh
flutter analyze
# lcov output lands in coverage/lcov.info; the C++ build kept a gcovr report in coverage/ too.
flutter test --coverage
