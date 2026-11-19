// Port of src/smapi/SmapiDetector.{h,cpp}.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/error_message.dart';
import '../common/json_text.dart';
import 'managed_assembly_version_reader.dart';
import 'smapi_version.dart';

enum SmapiState {
  invalidGamePath,
  notInstalled,
  installed,
  incomplete,
  componentMismatch,
  unreadable
}

/// @brief The result of inspecting a game directory for SMAPI.
class SmapiInstallation {
  SmapiState state = SmapiState.notInstalled;
  String gameDirectory = '';
  String executablePath = '';
  SmapiVersion? version;
  String diagnostic = '';

  /// @brief Returns true only for a complete installation with matching component versions.
  bool get isInstalled => state == SmapiState.installed;
}

const int _kMaximumMetadataSize = 16 * 1024 * 1024;

/// @brief Returns true when `directory/name` is a regular file.
bool _isRegularFile(String directory, String name) =>
    FileSystemEntity.typeSync(p.join(directory, name)) == FileSystemEntityType.file;

/// @brief Returns true when `directory/name` is a file that the current platform can execute.
bool isExecutableFile(String path) {
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) return false;
  // Windows has no executable permission bit, matching the C++ Q_OS_WIN branch.
  if (Platform.isWindows) return true;
  const anyExecuteBit = 0x49; // Octal 0111: owner, group, or other execute.
  return (stat.mode & anyExecuteBit) != 0;
}

/// @brief Returns the SMAPI executable file name for the current platform.
String smapiExecutableName() => Platform.isWindows ? 'StardewModdingAPI.exe' : 'StardewModdingAPI';

/// @brief Lists required SMAPI files that are absent from the game directory.
List<String> _missingFiles(String gameDirectory) {
  final missing = <String>[];
  final executable = smapiExecutableName();
  if (!isExecutableFile(p.join(gameDirectory, executable))) missing.add(executable);
  if (!_isRegularFile(gameDirectory, 'StardewModdingAPI.dll')) missing.add('StardewModdingAPI.dll');
  if (!_isRegularFile(gameDirectory, 'StardewModdingAPI.deps.json')) {
    missing.add('StardewModdingAPI.deps.json');
  }
  if (!_isRegularFile(gameDirectory, 'StardewModdingAPI.runtimeconfig.json')) {
    missing.add('StardewModdingAPI.runtimeconfig.json');
  }

  final internal = p.join(gameDirectory, 'smapi-internal');
  if (!Directory(internal).existsSync()) {
    missing.add('smapi-internal/');
    return missing;
  }
  if (!_isRegularFile(internal, 'metadata.json')) missing.add('smapi-internal/metadata.json');
  if (!_isRegularFile(internal, 'SMAPI.Toolkit.dll')) {
    missing.add('smapi-internal/SMAPI.Toolkit.dll');
  }
  if (!_isRegularFile(internal, 'SMAPI.Toolkit.CoreInterfaces.dll')) {
    missing.add('smapi-internal/SMAPI.Toolkit.CoreInterfaces.dll');
  }
  return missing;
}

/// @brief Validates SMAPI's commented JSON metadata and explains unreadable or invalid input.
bool _hasValidMetadata(String internal, ErrorMessage diagnostic) {
  final metadataFile = File(p.join(internal, 'metadata.json'));
  final stat = metadataFile.statSync();
  if (stat.type != FileSystemEntityType.file || stat.size > _kMaximumMetadataSize) {
    diagnostic.value = 'smapi-internal/metadata.json is missing or too large.';
    return false;
  }

  final List<int> data;
  try {
    data = metadataFile.readAsBytesSync();
  } on FileSystemException {
    diagnostic.value = 'smapi-internal/metadata.json could not be read.';
    return false;
  }
  if (data.length > _kMaximumMetadataSize) {
    diagnostic.value = 'smapi-internal/metadata.json is too large.';
    return false;
  }
  // SMAPI ships comments in this file, so strict JSON parsing rejects valid installations.
  Object? document;
  try {
    final withoutComments = stripJsonComments(utf8.decode(data, allowMalformed: true));
    document = withoutComments == null ? null : jsonDecode(withoutComments);
  } on FormatException {
    document = null;
  }
  if (document is! Map) {
    diagnostic.value = 'smapi-internal/metadata.json is not valid JSON.';
    return false;
  }
  return true;
}

/// @brief Inspects a game directory and reports SMAPI's installation state and version.
class SmapiDetector {
  const SmapiDetector();

  final ManagedAssemblyVersionReader _versionReader = const ManagedAssemblyVersionReader();

  /// @brief Inspects a SMAPI installation, resolving macOS bundle roots to their executable
  /// folder.
  SmapiInstallation inspect(String gameDirectory) {
    final result = SmapiInstallation();
    result.gameDirectory = p.normalize(p.absolute(gameDirectory));
    if (gameDirectory.isEmpty || !Directory(result.gameDirectory).existsSync()) {
      result.state = SmapiState.invalidGamePath;
      result.diagnostic = 'The configured Stardew Valley directory does not exist.';
      return result;
    }

    var gameDir = result.gameDirectory;
    if (Platform.isMacOS) {
      // Directory discovery returns the bundle root used by the launcher.
      final bundleExecutables = p.join(gameDir, 'Contents', 'MacOS');
      if (Directory(bundleExecutables).existsSync()) {
        gameDir = bundleExecutables;
        result.gameDirectory = gameDir;
      }
    }
    result.executablePath = p.join(gameDir, smapiExecutableName());

    final missing = _missingFiles(gameDir);
    if (missing.isEmpty) {
      final metadataDiagnostic = ErrorMessage();
      if (!_hasValidMetadata(p.join(gameDir, 'smapi-internal'), metadataDiagnostic)) {
        result.state = SmapiState.incomplete;
        result.diagnostic = metadataDiagnostic.value;
        return result;
      }
    } else {
      final hasSmapiFiles =
          FileSystemEntity.typeSync(result.executablePath) != FileSystemEntityType.notFound ||
              FileSystemEntity.typeSync(p.join(gameDir, 'smapi-internal')) !=
                  FileSystemEntityType.notFound ||
              FileSystemEntity.typeSync(p.join(gameDir, 'StardewModdingAPI.dll')) !=
                  FileSystemEntityType.notFound;
      if (!hasSmapiFiles) {
        result.state = SmapiState.notInstalled;
        result.diagnostic = 'SMAPI was not found in the configured game directory.';
        return result;
      }
      result.state = SmapiState.incomplete;
      result.diagnostic = 'SMAPI is incomplete. Missing: ${missing.join(', ')}';
      return result;
    }

    final internal = p.join(gameDir, 'smapi-internal');
    final firstError = ErrorMessage();
    final coreVersion = _versionReader.read(p.join(internal, 'SMAPI.Toolkit.dll'), firstError);
    final secondError = ErrorMessage();
    final interfacesVersion =
        _versionReader.read(p.join(internal, 'SMAPI.Toolkit.CoreInterfaces.dll'), secondError);
    if (coreVersion == null || interfacesVersion == null) {
      result.state = SmapiState.unreadable;
      result.diagnostic = !firstError.isEmpty ? firstError.value : secondError.value;
      return result;
    }
    if (coreVersion != interfacesVersion) {
      result.state = SmapiState.componentMismatch;
      result.version = coreVersion;
      result.diagnostic = 'SMAPI internal assemblies report different versions '
          '($coreVersion and $interfacesVersion).';
      return result;
    }

    result.state = SmapiState.installed;
    result.version = coreVersion;
    result.diagnostic = 'SMAPI is installed.';
    return result;
  }
}
