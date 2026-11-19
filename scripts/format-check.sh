#!/usr/bin/env bash
# Replaces the clang-format check: fails when any Dart file is not formatted.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/flutter-env.sh

dart format --output=none --set-exit-if-changed lib bin test
