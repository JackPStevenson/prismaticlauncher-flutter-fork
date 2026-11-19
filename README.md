# Prismatic Launcher (Flutter experiment)

> This is an experimental fork of [ChicoState/prismaticlauncher](https://github.com/ChicoState/prismaticlauncher)
> that replaces the C++20/Qt 6 application with a Flutter/Dart port. It exists to evaluate
> Flutter and is not intended to be merged back. See [Porting notes](#porting-notes-qt--flutter).

Prismatic Launcher is a Flutter desktop launcher for Stardew Valley. Its library provides
Add/Play/Edit and an instance page with Mods, Console, Settings, and Modpacks. Mods supports
local drag-and-drop installation into one shared game directory and browsing Nexus Mods.
SQLite data access and release packaging are not connected yet.

## Repository map

- `pubspec.yaml`, `pubspec.lock`: Dart/Flutter dependencies (they replace `vcpkg.json` and `CMakeLists.txt`).
- `analysis_options.yaml`: analyzer lints and formatter width (they replace `.clang-tidy`, `cppcheck.cfg`, and `.clang-format`).
- `lib/`: application code. Each file mirrors one C++ source:
  - `lib/smapi/`: SMAPI detection, managed-assembly version reading, launching (was `src/smapi/`).
  - `lib/mods/`: staged mod installation and archive validation (was `src/mods/`).
  - `lib/farmpack/`: FarmPack manifest loading (was `src/farmpack/`).
  - `lib/nexus_fetch_list/`: Nexus Mods API client (was `src/Nexus_fetchList/`).
  - `lib/ui/`: launcher UI, settings, theme, and the INI settings reader (was `src/qt/`).
  - `lib/common/`: small helpers shared by the above (error holder, relaxed-JSON cleanup).
  - `lib/main.dart`: entry point (was `src/qt/main.cpp`).
- `bin/nexus_fetch_list.dart`: command-line Nexus probe (was the `nexus-fetch-list` executable).
- `test/`: Flutter tests, ported from the QtTest suites with the same test names.
- `linux/`, `windows/`, `macos/`: generated Flutter desktop runners.
- `resources/`, `chickens/`: bundled images (declared as assets in `pubspec.yaml`, replacing `resources.qrc`).
- `scripts/`: format, analysis, CI, and build-and-run scripts.
- `Dockerfile.ci`: non-root Ubuntu image that runs format, analyzer, and tests; not a production image.
- `.github/workflows/`: upstream Qt workflows (inactive here); `.github/workflows.flutter/` holds the Flutter versions (see CI and releases).
- `documents/`: design notes and the infrastructure plan.
- `.agents/skills/`: repository-specific agent skills.

## Getting started

### 1. Install prerequisites

1. [Git](https://git-scm.com/downloads).
2. The [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel; the port was
   verified with Flutter 3.50.0 / Dart 3.14.0). The scripts use `flutter` from `PATH`, or
   `~/development/flutter`, or `FLUTTER_ROOT` when set.
3. Desktop toolchain for running the app:
   - **Linux / WSL:** `clang`, `cmake`, `ninja-build`, `pkg-config`, and `libgtk-3-dev`
     (`sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`).
   - **Windows:** Visual Studio 2022 with the "Desktop development with C++" workload.
   - **macOS:** Xcode.

Tests, the analyzer, and the formatter do not need the desktop toolchain.

### 2. Test and run

```bash
flutter pub get
flutter test
flutter run -d linux        # or: -d windows, -d macos
```

`./scripts/build-and-run.sh` (or `scripts\build-and-run.cmd` on Windows) runs the tests, then
launches the app. Pass `--config /absolute/path/launcher.ini` to use an alternate settings file:

```bash
./scripts/build-and-run.sh --config /tmp/launcher.ini
```

To make a live, read-only request to Nexus Mods, supply an API key only through the process
environment. The probe fetches the ten most recently updated mods, then prints each mod's
details one at a time. It never prints the key:

```bash
NEXUS_API_KEY='your-api-key' dart run bin/nexus_fetch_list.dart
```

To browse mods in the desktop UI, run the launcher with `NEXUS_API_KEY` set in its environment,
then click **Browse Nexus mods** on the library page. Select a name in the left-hand list to see
the author, version, endorsements, summary, and full details on the right. **Open download page**
opens the selected mod's Files tab on Nexus Mods; it does not install anything. The list loads
50 mods per page, sorted by latest update. Use **Previous** and **Next** to browse more, with a
result counter showing the total. The filter searches only the current page. **Refresh** returns
to the first page; **Back to library** returns to your instances. The key is kept in memory only;
after changing it, restart the launcher.

The test suite is network-free: Nexus tests use `http`'s `MockClient`. No `.env` file or local
service is needed. Do not add secrets, certificates, or game data to the repository.

### Game path and UI scope

The default game directory is `~/.local/share/Steam/steamapps/common/Stardew Valley`, the
conventional Ubuntu Steam location (`kDefaultGameDirectory` in `lib/ui/launcher_config.dart`).
In Settings, **Auto Detect Directory** checks the current path first, then common Steam locations
on Windows, macOS, and Linux (including Flatpak and Snap), additional libraries from Steam's
`libraryfolders.vdf`, and standard GOG locations. It accepts a folder only when the platform's
game executable is present. On macOS it selects the bundle root, with the executable under
`Contents/MacOS`. The locations follow
[SMAPI's game-path discovery](https://github.com/Pathoschild/SMAPI/blob/develop/build/find-game-folder.targets).

Detection fills the path field; **Save game path** persists it to a per-user INI file. The
location matches the Qt build, so both builds share one settings file: on Linux
`~/.config/Prismatic/Prismatic Launcher/launcher.ini` (or under `XDG_CONFIG_HOME`), on Windows
`%APPDATA%\Prismatic\Prismatic Launcher\launcher.ini`, and on macOS
`~/Library/Preferences/Prismatic/Prismatic Launcher/launcher.ini`. The settings page shows the
exact path.

```ini
[game]
directory=/home/your-user/.local/share/Steam/steamapps/common/Stardew Valley
```

Play validates and starts the selected game's executable from that folder. Vanilla uses
`StardewValley` on Linux; Modded uses an already-installed `StardewModdingAPI` with
`--developer-mode`. The game's output streams into the instance **Console**, which parses SMAPI
and BepInEx prefixes into level and source columns. Closing the launcher does not stop the game.
Add Instance creates session-only entries; modes and entries reset on restart, while the game
path persists.

### Configure ChickPix artwork

Open **Settings → Configure ChickPix**. Choose a bundled or custom image by filename. Duplicate
pictures and filenames appear once; bundled images take precedence. The dialog previews your
changes and lets you enable artwork and adjust opacity from 0% to 100%. **Save** applies the
changes to the library; **Cancel** discards them. The library's **ChickPix** button toggles the
artwork.

To add your own pictures, put PNG, JPG/JPEG, or WebP files in a `chickens` folder beside
`launcher.ini` or beside the launcher executable, then select **Refresh images**. Unsupported,
unreadable, or oversized files and links outside these folders are ignored. Limits are 16 MiB
per file, 8192 pixels per dimension, and 16 megapixels.

### Install local mods

1. Set the Stardew Valley game directory in **Settings** and save it. Install SMAPI separately
   and quit the game before changing mods.
2. On Nexus Mods, use the mod's **Files → Manual download** flow. The launcher's
   **Open download page** button opens that Files tab.
3. Open **Edit → Mods → Installed**. Drop one or more extracted folders or `.zip` archives onto
   the page, or use **Choose files…** / **Choose folder…**. This works offline without a Nexus
   key. Extract `.7z` and `.rar` downloads first; see [Porting notes](#porting-notes-qt--flutter).
4. Progress and results appear on the page and in the instance **Console**.

The installer finds `manifest.json` inside download wrappers and multi-mod bundles, preserves
each mod's assets, and copies complete mod folders. Loose files without a manifest are rejected
with an explanation. The full selection is validated and staged before installation; existing
mod IDs and folder collisions are rejected. Unsafe archive paths, links, corrupt archives, and
oversized inputs are rejected. Limits per selection are 100,000 entries, 2 GiB of extracted data,
512 MiB per file, and 64 folder levels. See [the design](documents/mod-installation.md).

The SMAPI dialog performs a read-only check of the configured game directory, validates SMAPI's
file layout and commented JSON metadata, and reads the version from SMAPI's managed assemblies
without executing them.

### 3. Quality checks

```bash
./scripts/format-check.sh          # dart format (100 columns)
./scripts/static-analysis.sh       # flutter analyze
./scripts/verify-infrastructure.sh # required files exist and every test file compiles
./scripts/ci-linux.sh              # everything above plus flutter test --coverage
```

To run the same checks in Docker:

```bash
docker build --pull=false -f Dockerfile.ci -t prismaticlauncher-ci:local .
docker run --rm prismaticlauncher-ci:local
```

## Porting notes (Qt → Flutter)

Every Dart file starts with a comment naming the C++ file it replaces and listing each
Qt-specific change. Summary of the intentional differences:

| Area | Qt build | Flutter build |
|---|---|---|
| Windows | Separate top-level windows | One window: instance and settings are pages; SMAPI, ChickPix, and Add Instance are dialogs |
| Archives | libarchive: ZIP, 7z, RAR | Pure-Dart `archive`: ZIP only; 7z/RAR show "extract first" guidance |
| Settings file | `QSettings` INI | Small INI reader/writer (`lib/ui/ini_file.dart`); same path and format |
| Signals/slots | Qt signals | Streams (Nexus client) and callbacks (widgets) |
| Background work | `QThread` | `Isolate.run` |
| Process output | `QProcess` merged channels | Separate stdout/stderr streams, each buffered per line |
| Console | Per-cell selection; viewport anchored to the viewed row | Per-row selection; follows the end only when already at the bottom |
| Filename collisions | NFC normalization + case folding | Lowercasing (Dart has no built-in NFC) |
| CI | Docker + native CMake/Qt on Windows and macOS | Single Linux job (format, analyze, test) |

## CI and releases

The Flutter CI workflows are parked in `.github/workflows.flutter/`; `.github/workflows/` still
holds the upstream Qt workflows, which fail on this fork. To switch, move the two files into
`.github/workflows/` (pushing workflow changes needs a GitHub token with the `workflow` scope,
for example `gh auth refresh -h github.com -s workflow`). Once moved, pull requests run format,
analyzer, and tests on Linux, plus Gitleaks. Native Windows/macOS desktop builds are not
validated in CI yet. The tag-triggered release workflow still fails
deliberately until a `packaging/` directory and the protected `release` environment exist.

## Troubleshooting

- **`flutter run -d linux` says GTK is missing:** install `libgtk-3-dev` (see prerequisites).
- **`flutter` is not found by the scripts:** put it on `PATH` or set `FLUTTER_ROOT`.
- **Docker cannot connect to the daemon:** start Docker Desktop (with WSL integration enabled)
  or the Docker Engine service.
