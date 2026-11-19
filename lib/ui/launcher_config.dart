// Port of src/qt/LauncherConfig.{h,cpp}.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'ini_file.dart';

// Port note: this was the `game/directory` value in src/qt/config/defaults.ini, a Qt
// resource. It is a constant now so the synchronous getters below need no asset loading.
// Conventional Ubuntu Steam installation. No installation discovery is performed here.
const String kDefaultGameDirectory = '~/.local/share/Steam/steamapps/common/Stardew Valley';

/// @brief Reads and writes launcher settings stored in an INI file.
class LauncherConfig {
  LauncherConfig(this._filePath);

  final String _filePath;

  /// @brief Returns the user's home directory, matching QDir::homePath().
  static String homePath() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/';

  /// @brief Expands a leading `~/` to the user's home directory.
  static String expandHome(String path) =>
      path.startsWith('~/') ? homePath() + path.substring(1) : path;

  /// @brief Returns the saved game directory, or the default when the value is not absolute.
  String gameDirectory() {
    final settings = IniFile(_filePath);
    final fallback = expandHome(kDefaultGameDirectory);
    final path = expandHome((settings.value('game/directory', fallback) ?? fallback).trim());
    return p.normalize(p.isAbsolute(path) ? path : fallback);
  }

  String filePath() => _filePath;

  /// @brief Saves an absolute game directory.
  /// @return True after syncing, or false for a relative path or an unwritable location.
  bool saveGameDirectory(String directory) {
    final path = expandHome(directory.trim());
    if (path.isEmpty || !p.isAbsolute(path)) return false;
    if (!_makeConfigDirectory()) return false;
    final settings = IniFile(_filePath)..setValue('game/directory', p.normalize(path));
    return settings.sync();
  }

  bool farmPackEnabled() => IniFile(_filePath).boolValue('appearance/farm-pack-enabled', true);

  /// @brief Saves visibility while retaining image and opacity.
  /// @return True after syncing the settings, or false on write failure.
  bool saveFarmPackEnabled(bool enabled) =>
      saveChickPix(farmPackImage(), farmPackOpacityPercent(), enabled);

  int farmPackOpacityPercent() =>
      IniFile(_filePath).intValue('appearance/farm-pack-opacity', 75).clamp(0, 100);

  /// @brief Saves opacity in 0–100 while retaining other values.
  /// @return True after syncing the settings, or false on invalid input or write failure.
  bool saveFarmPackOpacityPercent(int percent) =>
      saveChickPix(farmPackImage(), percent, farmPackEnabled());

  /// @brief Returns the saved image identifier; an empty legacy value uses Default artwork.
  String farmPackImage() => IniFile(_filePath).value('appearance/farm-pack-image') ?? '';

  /// @brief Syncs all three ChickPix values together.
  /// @return True after syncing the settings, or false on invalid opacity or write failure.
  bool saveChickPix(String image, int opacityPercent, bool enabled) {
    if (opacityPercent < 0 || opacityPercent > 100) return false;
    if (!_makeConfigDirectory()) return false;
    // Port note: the C++ version restored cached QSettings values after a failed sync,
    // because QSettings instances share an in-process cache. Each IniFile here re-reads the
    // file, so a failed write leaves nothing stale to restore.
    final settings = IniFile(_filePath)
      ..setValue('appearance/farm-pack-image', image)
      ..setValue('appearance/farm-pack-opacity', opacityPercent)
      ..setValue('appearance/farm-pack-enabled', enabled);
    return settings.sync();
  }

  bool _makeConfigDirectory() {
    try {
      Directory(p.dirname(p.absolute(_filePath))).createSync(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
