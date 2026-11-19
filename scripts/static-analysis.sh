#!/usr/bin/env bash
# Replaces clang-tidy and Cppcheck: runs the Dart analyzer with analysis_options.yaml.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/flutter-env.sh

flutter pub get >/dev/null
flutter analyze
