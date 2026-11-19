#!/usr/bin/env bash
# Tests, then runs the desktop app from any working directory.
# Extra arguments go to the app, for example: ./scripts/build-and-run.sh --config /tmp/launcher.ini
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repository_root"
source scripts/flutter-env.sh

case "$(uname -s)" in
    Darwin) device=macos ;;
    *) device=linux ;;
esac

flutter pub get
flutter test
if (($# > 0)); then
    exec flutter run -d "$device" --dart-entrypoint-args="$*"
fi
exec flutter run -d "$device"
