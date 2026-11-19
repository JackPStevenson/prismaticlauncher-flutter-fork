#!/usr/bin/env bash
# Checks that the Flutter project files exist and that tests are discoverable.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/flutter-env.sh

required_files=(
    pubspec.yaml
    pubspec.lock
    analysis_options.yaml
    .gitleaks.toml
    Dockerfile.ci
    .github/workflows.flutter/pr-checks.yml
    .github/workflows.flutter/release.yml
    linux/CMakeLists.txt
    windows/CMakeLists.txt
    macos/Runner.xcodeproj/project.pbxproj
)

for file in "${required_files[@]}"; do
    test -f "$file" || { echo "Missing infrastructure file: $file" >&2; exit 1; }
done

flutter pub get >/dev/null
# Flutter has no "list tests without running them" mode (CTest's --show-only). Instead,
# require test files to exist and let the analyzer prove that every one of them compiles.
test_files=$(find test -name '*_test.dart' | wc -l)
if [[ "$test_files" -eq 0 ]]; then
    echo 'No Flutter test files were found under test/.' >&2
    exit 1
fi
flutter analyze --no-pub test >/dev/null

echo "Infrastructure files are present and $test_files test files compile."
