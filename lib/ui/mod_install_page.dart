// Port of src/qt/ModInstallPage.{h,cpp}.
//
// Port notes:
// - QThread::create became `Isolate.run`, so the synchronous ModInstaller still runs off
//   the UI thread. As in Qt, only one operation runs at a time.
// - QFileDialog became the `file_selector` plugin, and Qt drag-and-drop events became the
//   `desktop_drop` plugin's DropTarget.
// - The `activity` signal became the `onActivity` callback. The instance window sends these
//   messages to its Console tab, so installs are visible there as they start and finish.

import 'dart:isolate';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../mods/mod_installer.dart';
import 'launcher_config.dart';
import 'style.dart';

/// @brief Results of one background operation (Work in the C++ code).
class _Work {
  _Work(this.install, this.listing);
  final ModInstallResult? install;
  final ModInstallResult listing;
}

/// @brief Optionally installs, then lists installed mods, on a background isolate.
///
/// Isolate.run copies everything its closure captures. A closure written inside a State
/// method captures `this` (and with it the whole widget tree), which cannot be sent, so the
/// closure is created here, where it can only capture these three plain values.
Future<_Work> _runInBackground(List<String> sources, String directory, bool installing) =>
    Isolate.run(() {
      final install = installing ? ModInstaller.install(sources, directory) : null;
      return _Work(install, ModInstaller.installed(directory));
    });

class ModInstallPage extends StatefulWidget {
  const ModInstallPage({
    super.key,
    required this.config,
    this.onActivity,
    this.onOperationFinished,
  });

  final LauncherConfig config;
  final void Function(String message)? onActivity;
  final void Function(bool success)? onOperationFinished;

  @override
  State<ModInstallPage> createState() => ModInstallPageState();
}

class ModInstallPageState extends State<ModInstallPage> {
  bool _busy = false;
  bool _dropActive = false;
  String _destination = '';
  String _status = 'Reading installed mods…';
  String? _result;
  List<InstalledMod> _mods = [];

  bool get isBusy => _busy;

  @override
  void initState() {
    super.initState();
    // Qt refreshed in showEvent; the Flutter page refreshes when it is first built.
    refresh();
  }

  /// @brief Re-reads installed mods from disk.
  Future<void> refresh() => _startOperation(const [], false);

  /// @brief Validates and installs the selected folders, files, or archives.
  Future<void> installSources(List<String> sources) async {
    if (sources.isNotEmpty) await _startOperation(sources, true);
  }

  Future<void> _startOperation(List<String> sources, bool installing) async {
    if (_busy) return;
    final directory = widget.config.gameDirectory();
    setState(() {
      _busy = true;
      _destination = 'Installing to: ${ModInstaller.modsDirectory(directory)}';
      _status = installing ? 'Validating and installing mods…' : 'Reading installed mods…';
    });
    if (installing) {
      widget.onActivity?.call('Installing ${sources.length} selection(s): ${sources.join(', ')}');
    }

    final work = await _runInBackground(sources, directory, installing);
    if (!mounted) return;

    String? message;
    if (installing) {
      final install = work.install!;
      final names = install.mods.map((mod) => mod.name).join(', ');
      message = install.succeeded
          ? 'Installed ${install.mods.length} mod(s) into '
              '${ModInstaller.modsDirectory(directory)}.\n$names'
          : 'Installation failed: ${install.error}';
      widget.onActivity?.call(message);
    }

    // If the game path changed while working, discard this listing and read the new one.
    final changed = widget.config.gameDirectory() != directory;
    setState(() {
      _busy = false;
      if (message != null) _result = message;
      if (!changed) {
        _mods = work.listing.mods;
        if (!work.listing.succeeded) {
          _status = work.listing.error;
        } else if (_mods.isEmpty) {
          _status = 'No mods installed. Drop a download or choose files to get started.';
        } else {
          _status = '${_mods.length} installed mod(s)';
        }
      } else {
        _mods = [];
      }
    });
    widget.onOperationFinished
        ?.call((!installing || work.install!.succeeded) && work.listing.succeeded);
    if (changed) await refresh();
  }

  Future<void> _chooseFiles() async {
    const archives = XTypeGroup(label: 'Mod archives', extensions: ['zip', '7z', 'rar']);
    const all = XTypeGroup(label: 'All files');
    final files = await openFiles(acceptedTypeGroups: const [archives, all]);
    if (files.isNotEmpty) await installSources(files.map((file) => file.path).toList());
  }

  Future<void> _chooseFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Choose extracted mod folder');
    if (path != null && path.isNotEmpty) await installSources([path]);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('modInstallPage'),
      color: LauncherColors.panel,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Installed mods', style: LauncherText.sectionTitle)),
          OutlinedButton(
            key: const ValueKey('refreshInstalledMods'),
            onPressed: _busy ? null : refresh,
            child: const Text('Refresh'),
          ),
        ]),
        const SizedBox(height: 12),
        SelectableText(_destination,
            key: const ValueKey('modInstallDestination'), style: LauncherText.muted),
        const SizedBox(height: 12),
        _buildDropZone(),
        const SizedBox(height: 12),
        Text(_status, key: const ValueKey('modInstallStatus'), style: LauncherText.muted),
        const SizedBox(height: 12),
        Expanded(child: _buildTable()),
        if (_result != null) ...[
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(maxHeight: 84),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFD0D5D8)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: SelectableText(_result!, key: const ValueKey('modInstallResult')),
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Quit the game before installing. SMAPI and required mods (such as Content Patcher) '
          'must be installed separately. Existing mods are never replaced.',
          style: LauncherText.muted,
        ),
      ]),
    );
  }

  Widget _buildDropZone() {
    return DropTarget(
      onDragEntered: (_) {
        if (!_busy) setState(() => _dropActive = true);
      },
      onDragExited: (_) => setState(() => _dropActive = false),
      onDragDone: (details) {
        setState(() => _dropActive = false);
        // Only local files are accepted, mirroring localDrop() in the C++ code.
        final sources = details.files.map((file) => file.path).where((path) => path.isNotEmpty);
        if (_busy || sources.isEmpty) return;
        installSources(sources.toList());
      },
      child: Container(
        key: const ValueKey('modDropZone'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _dropActive ? LauncherColors.dropActive : const Color(0xFFF8F9F9),
          border: Border.all(
            color: _dropActive ? LauncherColors.action : const Color(0xFFAAB3B8),
            width: _dropActive ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Drop mod downloads here',
              style: TextStyle(
                  color: LauncherColors.heading, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          // Port note: the Qt build also accepted 7z and RAR; see lib/mods/mod_installer.dart.
          const Text('Folders, ZIP archives, or a file inside an extracted mod.'),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton(
              key: const ValueKey('installModFiles'),
              onPressed: _busy ? null : _chooseFiles,
              child: const Text('Choose files…'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const ValueKey('installModFolder'),
              onPressed: _busy ? null : _chooseFolder,
              child: const Text('Choose folder…'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildTable() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: LauncherColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(children: [
        Container(
          color: const Color(0xFFF8F9F9),
          padding: const EdgeInsets.all(6),
          child: const Row(children: [
            Expanded(flex: 3, child: Text('Mod', style: TextStyle(fontWeight: FontWeight.w600))),
            Expanded(child: Text('Version', style: TextStyle(fontWeight: FontWeight.w600))),
            Expanded(
                flex: 3, child: Text('Unique ID', style: TextStyle(fontWeight: FontWeight.w600))),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('installedMods'),
            itemCount: _mods.length,
            itemBuilder: (context, index) {
              final mod = _mods[index];
              return Tooltip(
                message: mod.directory,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(children: [
                    Expanded(flex: 3, child: Text(mod.name)),
                    Expanded(child: Text(mod.version)),
                    Expanded(flex: 3, child: Text(mod.uniqueId)),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
