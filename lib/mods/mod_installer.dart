// Port of src/mods/ModInstaller.{h,cpp}.
//
// Installs SMAPI mods from folders, loose files inside an extracted mod, or ZIP archives.
// Everything is validated and staged inside the game folder first, then published into
// Mods/ with renames; any failure rolls back folders that were already published.
//
// Port notes:
// - libarchive (ZIP/7z/RAR) was replaced with the pure-Dart `archive` package, which reads
//   ZIP only. 7z and RAR archives are rejected with a clear message. This is the one
//   intentional feature gap of the Flutter port.
// - The C++ code threw `QString` and caught it at the public entry points. Dart does the
//   same with a private `_InstallFailure` exception.
// - Qt's NFC normalization + case folding for collision keys became `toLowerCase()`; Dart
//   has no built-in Unicode normalization. ASCII and most Latin names behave identically.
// - These functions are synchronous like the C++ versions. The UI runs them on a
//   background isolate (see lib/ui/mod_install_page.dart), as the C++ UI used QThread.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../common/json_text.dart';

const int maxFileBytes = 512 * 1024 * 1024;
const int maxTotalBytes = 2 * 1024 * 1024 * 1024;
const int maxEntries = 100000;
const int maxDepth = 64;

class InstalledMod {
  InstalledMod(this.name, this.version, this.uniqueId, this.directory);

  final String name;
  final String version;
  final String uniqueId;
  String directory;
}

class ModInstallResult {
  ModInstallResult([List<InstalledMod>? mods, this.error = '']) : mods = mods ?? [];

  final List<InstalledMod> mods;
  final String error;

  /// @brief Returns true when the operation completed without an error.
  bool get succeeded => error.isEmpty;
}

/// @brief Internal failure used in place of the C++ `throw QString`.
class _InstallFailure implements Exception {
  _InstallFailure(this.message);
  final String message;
}

/// @brief Aborts the current operation with a user-facing message.
Never _fail(String message) => throw _InstallFailure(message);

/// @brief Returns the comparison key used to detect cross-platform filename collisions.
String _key(String text) => text.toLowerCase();

/// @brief Returns true when [name] is a single, portable file or folder name.
bool _safeName(String name) {
  final invalid = RegExp(r'[<>:"/\\|?*\x00-\x1f]');
  final reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)', caseSensitive: false);
  return name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.endsWith('.') &&
      !name.endsWith(' ') &&
      !invalid.hasMatch(name) &&
      !reserved.hasMatch(name);
}

/// @brief Resolves a macOS bundle root to `Contents/MacOS` when that folder exists.
String _gameRoot(String directory) {
  final bundle = p.join(directory, 'Contents', 'MacOS');
  return p.normalize(p.absolute(Directory(bundle).existsSync() ? bundle : directory));
}

FileSystemEntityType _typeNoFollow(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false);

bool _isLink(String path) => _typeNoFollow(path) == FileSystemEntityType.link;

/// @brief Fails unless [directory] looks like a Stardew Valley installation with a safe Mods
/// destination.
void _validateGame(String directory) {
  if (directory.isEmpty || !p.isAbsolute(directory) || !Directory(directory).existsSync()) {
    _fail('Choose an existing Stardew Valley game directory in Settings.');
  }
  final game = _gameRoot(directory);
  const markers = [
    'StardewValley.dll',
    'Stardew Valley.exe',
    'StardewValley.exe',
    'StardewValley',
    'StardewModdingAPI.exe',
    'StardewModdingAPI',
  ];
  final hasMarker = markers.any(
      (marker) => FileSystemEntity.typeSync(p.join(game, marker)) == FileSystemEntityType.file);
  if (!hasMarker) {
    _fail('This folder does not contain Stardew Valley. Choose the game directory in Settings.');
  }
  final mods = p.join(game, 'Mods');
  final modsType = _typeNoFollow(mods);
  if (modsType == FileSystemEntityType.link ||
      (modsType != FileSystemEntityType.notFound && modsType != FileSystemEntityType.directory)) {
    _fail('The Mods destination must be a regular directory, not a link or file.');
  }
}

/// @brief Tracks entry count, folder depth, and bytes copied for one operation.
class _Budget {
  int entries = 0;
  int bytes = 0;

  void entry(int depth) {
    if (++entries > maxEntries || depth > maxDepth) {
      _fail('The selection exceeds the 100,000-entry or 64-level folder limit.');
    }
  }

  void data(int count, int fileBytes) {
    bytes += count;
    if (fileBytes > maxFileBytes || bytes > maxTotalBytes) {
      _fail('The selection exceeds the 512 MiB file or 2 GiB total size limit.');
    }
  }
}

/// @brief Returns true for files with a supported or recognized archive extension.
bool _isArchive(String path) {
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) return false;
  return const ['zip', '7z', 'rar'].contains(_suffix(path));
}

String _suffix(String path) => p.extension(path).replaceFirst('.', '').toLowerCase();

/// @brief Extracts a ZIP archive into [destination] after validating every entry.
void _extractArchive(String source, String destination, _Budget budget) {
  // Port note: libarchive also read 7z and RAR; the pure-Dart reader only supports ZIP.
  if (_suffix(source) != 'zip') {
    _fail('7z and RAR archives are not supported in the Flutter build yet. '
        'Extract the archive and choose the folder instead: $source');
  }

  final Archive archive;
  InputFileStream? input;
  try {
    input = InputFileStream(source);
    archive = ZipDecoder().decodeStream(input);
  } catch (_) {
    input?.closeSync();
    _fail('Cannot open archive; it may be corrupt or unsupported: $source');
  }

  try {
    final spellings = <String, String>{};
    final entries = <String>{};
    for (final entry in archive) {
      final path = entry.name.replaceAll('\\', '/');
      if (path.startsWith('/')) _fail('Archive contains an absolute path: $path');
      final parts = path.split('/').where((part) => part.isNotEmpty).toList();
      while (parts.isNotEmpty && parts.first == '.') {
        parts.removeAt(0);
      }
      budget.entry(parts.length);
      if (parts.isEmpty) {
        if (entry.isDirectory) continue;
        _fail('Archive contains an empty filename.');
      }

      // Reject names that differ only by case so the install behaves the same on all OSes.
      var relative = '';
      for (final part in parts) {
        if (!_safeName(part)) _fail('Archive contains an unsafe filename: $path');
        relative = relative.isEmpty ? part : '$relative/$part';
        final folded = _key(relative);
        if (spellings.containsKey(folded) && spellings[folded] != relative) {
          _fail('Archive contains filenames that conflict across platforms: $path');
        }
        spellings[folded] = relative;
      }
      if (entries.contains(_key(relative))) _fail('Archive contains a duplicate entry: $relative');
      entries.add(_key(relative));

      if (entry.isSymbolicLink) {
        _fail('Archive links and special files cannot be installed: $relative');
      }
      final target = p.joinAll([destination, ...parts]);
      if (entry.isDirectory) {
        try {
          Directory(target).createSync(recursive: true);
        } on FileSystemException {
          _fail('Cannot create archive staging folder.');
        }
        continue;
      }
      if (entry.size > maxFileBytes) _fail('An archive file exceeds the 512 MiB size limit.');
      try {
        Directory(p.dirname(target)).createSync(recursive: true);
      } on FileSystemException {
        _fail('Cannot create archive staging folder.');
      }
      if (_typeNoFollow(target) != FileSystemEntityType.notFound) {
        _fail('Cannot stage archive file: $relative');
      }

      final List<int> content;
      try {
        content = entry.readBytes() ?? const <int>[];
      } catch (_) {
        _fail('Archive is corrupt or cannot be decoded: $source');
      }
      budget.data(content.length, content.length);
      try {
        File(target).writeAsBytesSync(content, flush: true);
      } on FileSystemException {
        _fail('Cannot write archive staging file.');
      }
    }
  } finally {
    input.closeSync();
  }
}

/// @brief Recursively copies [source] into [destination], refusing links and special files.
void _copyTree(String source, String destination, _Budget budget, [int depth = 0]) {
  budget.entry(depth);
  final type = _typeNoFollow(source);
  if (type == FileSystemEntityType.link ||
      (type != FileSystemEntityType.file && type != FileSystemEntityType.directory)) {
    _fail('Links and special files cannot be installed: $source');
  }
  if (type == FileSystemEntityType.directory) {
    try {
      Directory(destination).createSync(recursive: true);
    } on FileSystemException {
      _fail('Cannot create staging folder: $destination');
    }
    final names = <String>{};
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(source).listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      _fail('Cannot read: $source');
    }
    for (final child in entries) {
      final name = p.basename(child.path);
      if (!_safeName(name) || names.contains(_key(name))) {
        _fail('Unsafe or conflicting filename: ${child.path}');
      }
      names.add(_key(name));
      _copyTree(child.path, p.join(destination, name), budget, depth + 1);
    }
    return;
  }

  final input = File(source);
  final size = input.lengthSync();
  if (size > maxFileBytes) _fail('A file exceeds the 512 MiB size limit: $source');
  if (_typeNoFollow(destination) != FileSystemEntityType.notFound) {
    _fail('Cannot stage file: $source');
  }
  RandomAccessFile? reader;
  RandomAccessFile? writer;
  try {
    reader = input.openSync();
    writer = File(destination).openSync(mode: FileMode.writeOnly);
    var fileBytes = 0;
    while (true) {
      final block = reader.readSync(64 * 1024);
      if (block.isEmpty) break;
      fileBytes += block.length;
      budget.data(block.length, fileBytes);
      writer.writeFromSync(block);
    }
    writer.flushSync();
  } on FileSystemException {
    _fail('Cannot stage file: $source');
  } finally {
    reader?.closeSync();
    writer?.closeSync();
  }
}

/// @brief Finds a JSON property, falling back to a case-insensitive name match.
Object? _property(Map<String, dynamic> json, String name) {
  if (json.containsKey(name)) return json[name];
  // SMAPI binds JSON properties without requiring exact capitalization; its
  // bundled mods use UniqueId while many downloaded mods use UniqueID.
  for (final entry in json.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

/// @brief Returns a trimmed string property, or an empty string when absent or not a string.
String _field(Map<String, dynamic> json, String name) {
  final member = _property(json, name);
  return member is String ? member.trim() : '';
}

/// @brief Removes comments and trailing commas that SMAPI's JSON reader tolerates.
String _normalizeManifest(String data) {
  // SMAPI's JSON reader accepts author comments and trailing commas. Preserve
  // quoted strings exactly, including URLs and text containing comma/braces.
  final withoutComments = stripJsonComments(data);
  if (withoutComments == null) _fail('Unterminated comment in mod manifest.');
  return stripTrailingCommas(withoutComments);
}

/// @brief Returns the deepest object/array nesting level in decoded JSON.
int _nestingDepth(Object? value) {
  if (value is Map) {
    var deepest = 0;
    for (final child in value.values) {
      deepest = math.max(deepest, _nestingDepth(child));
    }
    return deepest + 1;
  }
  if (value is List) {
    var deepest = 0;
    for (final child in value) {
      deepest = math.max(deepest, _nestingDepth(child));
    }
    return deepest + 1;
  }
  return 0;
}

/// @brief Reads and validates `manifest.json` in [directory].
///
/// When [checkPayload] is true, also requires exactly one of EntryDll or ContentPackFor and
/// checks that EntryDll exists inside the folder.
InstalledMod _readMod(String directory, bool checkPayload) {
  final manifest = p.join(directory, 'manifest.json');
  const maximumManifestBytes = 1024 * 1024;
  final String text;
  try {
    if (_isLink(manifest)) throw const FileSystemException();
    final file = File(manifest);
    if (file.lengthSync() > maximumManifestBytes) throw const FileSystemException();
    text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    _fail('Cannot read manifest (maximum 1 MiB): $manifest');
  }

  final data = _normalizeManifest(text);
  Object? json;
  try {
    json = jsonDecode(data);
  } on FormatException {
    json = null;
  }
  // Port note: nlohmann enforced the depth limit while parsing; Dart checks afterwards.
  if (_nestingDepth(json) > maxDepth + 1) {
    _fail('Manifest exceeds the 64-level JSON nesting limit: $manifest');
  }
  if (json is! Map<String, dynamic>) _fail('Invalid JSON in manifest: $manifest');

  final mod = InstalledMod(
      _field(json, 'Name'), _field(json, 'Version'), _field(json, 'UniqueID'), directory);
  if (mod.name.isEmpty ||
      mod.version.isEmpty ||
      mod.uniqueId.isEmpty ||
      _field(json, 'Author').isEmpty ||
      _field(json, 'Description').isEmpty) {
    _fail('Manifest needs Name, Author, Version, Description and UniqueID: $manifest');
  }
  if (checkPayload) {
    final dll = _field(json, 'EntryDll');
    final pack = _property(json, 'ContentPackFor');
    final isPack = pack is Map<String, dynamic> && _field(pack, 'UniqueID').isNotEmpty;
    if (dll.isNotEmpty == isPack) {
      _fail('Manifest must specify EntryDll or ContentPackFor: $manifest');
    }
    if (dll.isNotEmpty &&
        (!_safeName(dll) ||
            FileSystemEntity.typeSync(p.join(directory, dll)) != FileSystemEntityType.file)) {
      _fail('EntryDll is missing or unsafe: $manifest');
    }
  }
  return mod;
}

/// @brief Recursively collects mods: a folder with `manifest.json` is one mod.
void _discover(String directory, List<InstalledMod> mods, _Budget budget, bool checkPayload,
    [int depth = 0]) {
  budget.entry(depth);
  if (_isLink(directory)) _fail('A mod folder cannot be a link: $directory');
  if (FileSystemEntity.typeSync(p.join(directory, 'manifest.json')) !=
      FileSystemEntityType.notFound) {
    mods.add(_readMod(directory, checkPayload));
    return;
  }
  final List<FileSystemEntity> children;
  try {
    children = Directory(directory)
        .listSync(followLinks: false)
        .where((child) => _typeNoFollow(child.path) != FileSystemEntityType.file)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  } on FileSystemException {
    _fail('Cannot read mod folder: $directory');
  }
  for (final child in children) {
    // SMAPI ignores dot-prefixed folders; never scan an install in progress.
    if (p.basename(child.path).startsWith('.')) continue;
    _discover(child.path, mods, budget, checkPayload, depth + 1);
  }
}

/// @brief Returns true when either path is equal to, or nested inside, the other.
bool _overlaps(String first, String second) {
  final a = _key(p.normalize(first));
  final b = _key(p.normalize(second));
  return a == b || p.isWithin(a, b) || p.isWithin(b, a);
}

/// @brief Resolves a selected source to the mod folder that should be copied.
///
/// A folder is used as-is; a loose file resolves to the nearest ancestor with a manifest.
String _sourceRoot(String source) {
  final type = _typeNoFollow(source);
  if (type == FileSystemEntityType.notFound || type == FileSystemEntityType.link) {
    _fail('Source is missing or is a link: $source');
  }
  if (type == FileSystemEntityType.directory) return Directory(source).resolveSymbolicLinksSync();
  var parent = p.dirname(p.absolute(source));
  for (var depth = 0; depth <= maxDepth; ++depth) {
    if (FileSystemEntity.typeSync(p.join(parent, 'manifest.json')) == FileSystemEntityType.file) {
      return Directory(parent).resolveSymbolicLinksSync();
    }
    final next = p.dirname(parent);
    if (next == parent) break;
    parent = next;
  }
  _fail('No manifest.json found for ${p.basename(source)}. '
      'Select a complete extracted SMAPI mod folder or download archive. '
      'Loose DLL/XNB files cannot be installed safely.');
}

class ModInstaller {
  ModInstaller._();

  /// @brief Returns the Mods folder, resolving a configured macOS bundle root to
  /// Contents/MacOS when present.
  static String modsDirectory(String gameDirectory) => p.join(_gameRoot(gameDirectory), 'Mods');

  /// @brief Reads manifests from disk without following links. Errors prevent installation.
  static ModInstallResult installed(String gameDirectory) {
    try {
      _validateGame(gameDirectory);
      final result = ModInstallResult();
      final directory = modsDirectory(gameDirectory);
      if (FileSystemEntity.typeSync(directory) != FileSystemEntityType.notFound) {
        _discover(directory, result.mods, _Budget(), false);
      }
      result.mods.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return result;
    } on _InstallFailure catch (error) {
      return ModInstallResult(null, error.message);
    }
  }

  /// @brief Copies sources; never executes them or overwrites existing mods.
  ///
  /// All sources are validated and staged before publishing; failures roll back new folders.
  static ModInstallResult install(List<String> sources, String gameDirectory) {
    final published = <String>[];
    Directory? staging;
    try {
      _validateGame(gameDirectory);
      if (sources.isEmpty) _fail('Select at least one mod folder or file.');
      final existing = installed(gameDirectory);
      if (!existing.succeeded) _fail(existing.error);
      final game = Directory(_gameRoot(gameDirectory)).resolveSymbolicLinksSync();
      final destination = modsDirectory(game);
      // Staging lives in the game folder so the final publish is a same-volume rename.
      try {
        staging = Directory(game).createTempSync('.prismatic-install-');
      } on FileSystemException {
        _fail('Cannot stage mods. Check game-folder write permissions.');
      }

      final budget = _Budget();
      final roots = <String>{};
      final candidates = <InstalledMod>[];
      for (final source in sources) {
        final type = _typeNoFollow(source);
        if (type == FileSystemEntityType.notFound || type == FileSystemEntityType.link) {
          _fail('Source is missing or is a link: $source');
        }
        final archived = _isArchive(source);
        final root = archived ? File(source).resolveSymbolicLinksSync() : _sourceRoot(source);
        if (_overlaps(root, game)) _fail('Select mod downloads outside the game directory.');
        if (roots.contains(root)) continue;
        roots.add(root);
        final package = p.join(staging.path, '${roots.length}');
        final name = archived ? 'unpacked' : p.basename(root);
        if (!_safeName(name) || name.startsWith('.')) _fail('Unsafe mod folder name: $name');
        final target = p.join(package, name);
        if (archived) {
          if (File(root).lengthSync() > maxFileBytes) {
            _fail('The archive exceeds the 512 MiB input size limit.');
          }
          _extractArchive(root, target, budget);
        } else {
          _copyTree(root, target, budget);
        }

        final before = candidates.length;
        _discover(target, candidates, _Budget(), true);
        if (candidates.length == before) _fail('No SMAPI mod manifests found in: $source');
        // An archive with its manifest at the top level gets a folder named after its ID.
        if (archived && candidates.length == before + 1 && candidates.last.directory == target) {
          final folder = candidates.last.uniqueId;
          if (!_safeName(folder) || folder.startsWith('.')) _fail('Unsafe mod UniqueID: $folder');
          final renamed = p.join(package, folder);
          if (target != renamed) {
            try {
              Directory(target).renameSync(renamed);
            } on FileSystemException {
              _fail('Cannot name staged mod folder.');
            }
          }
          candidates.last.directory = renamed;
        }
      }

      // Validate the whole batch against existing mods before publishing anything.
      final ids = <String>{};
      final names = <String>{};
      for (final mod in existing.mods) {
        ids.add(_key(mod.uniqueId));
      }
      if (Directory(destination).existsSync()) {
        for (final entry in Directory(destination).listSync(followLinks: false)) {
          names.add(_key(p.basename(entry.path)));
        }
      }
      for (final mod in candidates) {
        final name = p.basename(mod.directory);
        if (!_safeName(name) || name.startsWith('.')) _fail('Unsafe mod folder name: $name');
        if (ids.contains(_key(mod.uniqueId))) {
          _fail('Mod ${mod.uniqueId} is already installed or selected more than once. '
              'Remove the existing copy before installing a replacement.');
        }
        if (names.contains(_key(name))) {
          _fail('A mod folder named $name already exists or is selected twice.');
        }
        ids.add(_key(mod.uniqueId));
        names.add(_key(name));
      }
      try {
        Directory(destination).createSync(recursive: true);
      } on FileSystemException {
        _fail('Cannot create Mods folder. Check write permissions.');
      }

      final result = ModInstallResult();
      for (final mod in candidates) {
        final target = p.join(destination, p.basename(mod.directory));
        try {
          Directory(mod.directory).renameSync(target);
        } on FileSystemException {
          _fail('Cannot install folder: $target');
        }
        published.add(target);
        mod.directory = target;
        result.mods.add(mod);
      }
      return result;
    } on _InstallFailure catch (error) {
      var message = error.message;
      for (final directory in published) {
        try {
          Directory(directory).deleteSync(recursive: true);
        } on FileSystemException {
          message += '\nCould not roll back new folder; remove it manually: $directory';
        }
      }
      return ModInstallResult(null, message);
    } finally {
      // QTemporaryDir removed its folder automatically; Dart must do so explicitly.
      try {
        staging?.deleteSync(recursive: true);
      } on FileSystemException {
        // Leftover staging folders start with "." so SMAPI ignores them.
      }
    }
  }
}
