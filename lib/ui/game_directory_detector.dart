// Port of src/qt/GameDirectoryDetector.{h,cpp}.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'launcher_config.dart';

/// @brief Converts Windows separators to `/`, matching QDir::fromNativeSeparators.
String _fromNativeSeparators(String path) => Platform.isWindows ? path.replaceAll('\\', '/') : path;

/// @brief Returns [candidate] as a normalized game directory when it contains the game
/// executable, or an empty string otherwise.
String _installationAt(String candidate) {
  var path = _fromNativeSeparators(LauncherConfig.expandHome(candidate.trim()));
  if (path.isEmpty || !p.isAbsolute(path)) return '';
  path = p.normalize(path);
  final String executable;
  if (Platform.isWindows) {
    executable = 'Stardew Valley.exe';
  } else if (Platform.isMacOS) {
    // Settings and launch actions use the bundle root; SMAPI lives inside the bundle.
    const suffix = '/Contents/MacOS';
    if (path.endsWith(suffix)) path = path.substring(0, path.length - suffix.length);
    executable = 'Contents/MacOS/StardewValley';
  } else {
    executable = 'StardewValley';
  }
  return FileSystemEntity.typeSync(p.join(path, executable)) == FileSystemEntityType.file
      ? path
      : '';
}

/// @brief Reads extra Steam library folders listed in Steam's `libraryfolders.vdf` files.
List<String> _additionalLibraries(String steamRoot) {
  const maximumSize = 1024 * 1024;
  final pathEntry = RegExp(r'"(?:path|[0-9]+)"\s*"((?:\\.|[^"\\])*)"');
  final libraries = <String>[];
  for (final name in const ['steamapps/libraryfolders.vdf', 'config/libraryfolders.vdf']) {
    final file = File(p.join(steamRoot, name));
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file || stat.size > maximumSize) continue;
    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      continue;
    }
    if (bytes.length > maximumSize) continue;
    for (final entry in pathEntry.allMatches(utf8.decode(bytes, allowMalformed: true))) {
      if (libraries.length >= 128) break;
      var library = entry.group(1)!;
      library = library.replaceAll(r'\\', '\\').replaceAll(r'\"', '"');
      library = _fromNativeSeparators(library);
      if (p.isAbsolute(library)) libraries.add(p.normalize(library));
    }
  }
  return libraries.toSet().toList();
}

/// @brief Reads one registry value on Windows through `reg query`.
///
/// Port note: QSettings could read the registry directly. Dart has no registry API without
/// a plugin, so the built-in `reg.exe` tool is queried instead; it only reads values.
String _readRegistry(String key, String valueName, {bool use32BitView = false}) {
  if (!Platform.isWindows) return '';
  try {
    final result =
        Process.runSync('reg', ['query', key, '/v', valueName, if (use32BitView) '/reg:32']);
    if (result.exitCode != 0) return '';
    final match = RegExp('$valueName\\s+REG_\\w+\\s+(.+)').firstMatch(result.stdout as String);
    return match?.group(1)?.trim() ?? '';
  } on ProcessException {
    return '';
  }
}

class GameDirectoryDetector {
  /// @brief Builds the platform's well-known Steam roots and game folders.
  GameDirectoryDetector()
      : _steamRoots = [],
        _gameDirectories = [] {
    final home = LauncherConfig.homePath();
    if (Platform.isWindows) {
      _steamRoots.add(_readRegistry(r'HKCU\Software\Valve\Steam', 'SteamPath'));
      _gameDirectories.add(_readRegistry(
          r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 413150',
          'InstallLocation'));
      _gameDirectories.add(
          _readRegistry(r'HKLM\SOFTWARE\GOG.com\Games\1453375253', 'PATH', use32BitView: true));
      for (final variable in const ['ProgramFiles(x86)', 'ProgramFiles']) {
        final programs = Platform.environment[variable] ?? '';
        if (programs.isEmpty) continue;
        _steamRoots.add(p.join(programs, 'Steam'));
        _gameDirectories
          ..add(p.join(programs, 'GOG Galaxy/Games/Stardew Valley'))
          ..add(p.join(programs, 'GOG Games/Stardew Valley'));
      }
    } else if (Platform.isMacOS) {
      _steamRoots.add('$home/Library/Application Support/Steam');
      _gameDirectories
        ..add('/Applications/Stardew Valley.app')
        ..add('$home/Applications/Stardew Valley.app');
    } else {
      final dataHome = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
      _steamRoots.addAll([
        '$dataHome/Steam',
        '$home/.local/share/Steam',
        '$home/.steam/steam',
        '$home/.steam/root',
        '$home/.var/app/com.valvesoftware.Steam/data/Steam',
        '$home/snap/steam/common/.local/share/Steam',
      ]);
      _gameDirectories
        ..add('$home/GOG Games/Stardew Valley/game')
        ..add('$home/GOGGames/StardewValley/game');
    }
    final unique = _steamRoots.toSet().toList();
    _steamRoots
      ..clear()
      ..addAll(unique);
  }

  /// @brief Uses explicit search locations; tests rely on this to avoid the real system.
  GameDirectoryDetector.withLocations(List<String> steamRoots,
      [List<String> gameDirectories = const []])
      : _steamRoots = List.of(steamRoots),
        _gameDirectories = List.of(gameDirectories);

  final List<String> _steamRoots;
  final List<String> _gameDirectories;

  /// @brief Prefers the supplied installation, then searches known locations without
  /// modifying any files.
  /// @return An absolute game directory (bundle root on macOS), or empty when none is found.
  String detect([String preferredDirectory = '']) {
    final preferred = _installationAt(preferredDirectory);
    if (preferred.isNotEmpty) return preferred;

    for (final root in _steamRoots) {
      final steamRoot = _fromNativeSeparators(root);
      if (steamRoot.isEmpty || !p.isAbsolute(steamRoot)) continue;
      final libraries = [steamRoot, ..._additionalLibraries(steamRoot)];
      for (final library in libraries) {
        for (final steamApps in const ['steamapps', 'SteamApps']) {
          final directory = _installationAt(p.join(library, steamApps, 'common', 'Stardew Valley'));
          if (directory.isNotEmpty) return directory;
        }
      }
    }
    for (final candidate in _gameDirectories) {
      final directory = _installationAt(candidate);
      if (directory.isNotEmpty) return directory;
    }
    return '';
  }
}
