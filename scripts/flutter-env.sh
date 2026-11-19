#!/usr/bin/env bash
# Shared helper sourced by the other scripts: puts a Flutter SDK on PATH.
# Uses `flutter` from PATH when present, otherwise the conventional ~/development/flutter
# install used in this experiment. Override with FLUTTER_ROOT=/path/to/flutter.
if ! command -v flutter >/dev/null 2>&1; then
    flutter_root="${FLUTTER_ROOT:-$HOME/development/flutter}"
    if [[ -x "$flutter_root/bin/flutter" ]]; then
        export PATH="$flutter_root/bin:$PATH"
    else
        echo "Flutter SDK not found. Install it or set FLUTTER_ROOT." >&2
        exit 1
    fi
fi
