// Port of src/qt/settings.{h,cpp,ui} (the launcher settings window).
//
// Port note: the Qt version was a separate top-level window. Flutter desktop apps have one
// window, so settings is a full-page route; "← Library" pops back to the launcher.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'chick_pix_dialog.dart';
import 'game_directory_detector.dart';
import 'launcher_config.dart';
import 'style.dart';

class Settings extends StatefulWidget {
  /// @brief Builds game-path settings and the entry to the ChickPix editor.
  const Settings({
    super.key,
    required this.config,
    this.detector,
    this.onChickPixChanged,
    this.onGameDirectoryChanged,
    this.onBackToLibraryRequested,
  });

  final LauncherConfig config;
  // Tests inject a detector with fake search locations.
  final GameDirectoryDetector? detector;

  // ------ signals ------
  /// @brief Announces that the ChickPix editor successfully synced its pending settings.
  final VoidCallback? onChickPixChanged;
  final void Function(String directory)? onGameDirectoryChanged;
  final VoidCallback? onBackToLibraryRequested;

  @override
  State<Settings> createState() => SettingsState();
}

class SettingsState extends State<Settings> {
  final TextEditingController _gameDirectoryValue = TextEditingController();
  late final GameDirectoryDetector _detector = widget.detector ?? GameDirectoryDetector();
  String _pathStatus = '';

  @override
  void initState() {
    super.initState();
    reload();
    _initialized = true;
  }

  // setState() may not be called during initState, which runs reload() once.
  bool _initialized = false;
  void _apply(VoidCallback update) => _initialized ? setState(update) : update();

  @override
  void dispose() {
    _gameDirectoryValue.dispose();
    super.dispose();
  }

  /// @brief Shows the saved game directory and whether it exists.
  void reload() {
    final directory = widget.config.gameDirectory();
    _gameDirectoryValue.text = directory;
    final message = Directory(directory).existsSync()
        ? 'Game folder exists. Play checks the selected executable.'
        : 'Game folder not found. Choose your installation directory.';
    _apply(() => _pathStatus = '$message\nSettings file: ${widget.config.filePath()}');
  }

  void _detectGameDirectory() {
    final directory = _detector.detect(_gameDirectoryValue.text);
    _apply(() {
      if (directory.isEmpty) {
        _pathStatus = 'Could not detect Stardew Valley. Choose your game folder with Browse.';
      } else {
        _gameDirectoryValue.text = directory;
        _pathStatus = 'Detected game directory. Select Save game path to use it.';
      }
    });
  }

  void _saveGameDirectory() {
    if (!widget.config.saveGameDirectory(_gameDirectoryValue.text)) {
      _apply(() =>
          _pathStatus = 'Could not save. Use an absolute path and a writable config location.');
      return;
    }
    reload();
    _apply(() => _pathStatus = 'Saved game path.\n$_pathStatus');
    widget.onGameDirectoryChanged?.call(widget.config.gameDirectory());
  }

  Future<void> _browseDirectory() async {
    final directory = await getDirectoryPath(
        confirmButtonText: 'Select Stardew Valley folder',
        initialDirectory: _gameDirectoryValue.text);
    if (directory != null && directory.isNotEmpty) _gameDirectoryValue.text = directory;
  }

  /// @brief Opens the ChickPix editor.
  void _configureChickPix() =>
      ChickPixDialog.show(context, widget.config, onSaved: widget.onChickPixChanged);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('settingsPage'),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextButton(
            key: const ValueKey('backLibrary'),
            onPressed: widget.onBackToLibraryRequested,
            child: const Text('←  Library'),
          ),
          const SizedBox(height: 16),
          const Text('Launcher settings', style: LauncherText.sectionTitle),
          const SizedBox(height: 16),
          Row(children: [
            const SizedBox(width: 130, child: Text('Game Directory')),
            Expanded(
              child: TextField(
                key: const ValueKey('gameDirectoryValue'),
                controller: _gameDirectoryValue,
                decoration:
                    const InputDecoration(hintText: 'Stardew Valley installation directory'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const ValueKey('browseDirectory'),
              onPressed: _browseDirectory,
              child: const Text('Browse…'),
            ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
              key: const ValueKey('detectDirectory'),
              onPressed: _detectGameDirectory,
              child: const Text('Auto Detect Directory'),
            ),
            FilledButton(
              key: const ValueKey('savePath'),
              onPressed: _saveGameDirectory,
              child: const Text('Save game path'),
            ),
            OutlinedButton(
              key: const ValueKey('configureChickPix'),
              onPressed: _configureChickPix,
              child: const Text('Configure ChickPix'),
            ),
          ]),
          const SizedBox(height: 12),
          Text(_pathStatus, key: const ValueKey('pathStatus')),
        ]),
      ),
    );
  }
}
