// Port of src/qt/InstanceWindow.{h,cpp,ui}.
//
// Port notes:
// - The Qt InstanceWindow was a reusable QMainWindow that kept its console and running game
//   process while hidden. Flutter rebuilds pages on navigation, so that long-lived state
//   moved into `InstanceWindowController`, which the LauncherWindow owns and reuses. The
//   `InstanceWindow` widget is the page that draws it.
// - QProcess became dart:io Process. stdout and stderr are both streamed into the console
//   (QProcess::MergedChannels), with a stateful UTF-8 decoder per stream.
// - QMessageBox::warning became an AlertDialog shown by the page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../smapi/smapi_detector.dart';
import 'launcher_config.dart';
import 'log_window.dart';
import 'mod_install_page.dart';
import 'nexus_page.dart';
import 'style.dart';

/// @brief A launch problem that the page should show in a warning dialog.
class LaunchWarning {
  const LaunchWarning(this.title, this.message);
  final String title;
  final String message;
}

/// @brief Sidebar sections, in the same order as the Qt `navigation` list.
enum InstanceTab { mods, console, settings, modpacks }

/// @brief Long-lived instance state: name, launch mode, console history, and game process.
class InstanceWindowController extends ChangeNotifier {
  /// @brief Creates instance state that borrows the shared launcher configuration.
  InstanceWindowController(String name, bool modded, this.config)
      : _name = name,
        _modded = modded;

  final LauncherConfig config;
  final LogWindowController logWindow = LogWindowController();

  String _name;
  bool _modded;
  InstanceTab selectedTab = InstanceTab.mods;
  int modViewIndex = 0;
  bool modsLoaded = false;
  String statusMessage = '';
  bool _processRunning = false;
  bool _disposed = false;

  /// @brief Called with true (modded) or false (vanilla) after the user changes the mode.
  void Function(bool modded)? launchModeChanged;

  /// @brief Asks the owner to open launcher settings for the shared game directory.
  VoidCallback? settingsRequested;

  String get name => _name;
  bool get modded => _modded;
  bool get isGameRunning => _processRunning;

  /// @brief Updates the instance title and launch mode without emitting a mode change.
  void setInstance(String name, bool modded) {
    _name = name;
    _modded = modded;
    notifyListeners();
  }

  /// @brief Applies a user-selected launch mode and announces it.
  void setLaunchMode(bool modded) {
    _modded = modded;
    launchModeChanged?.call(modded);
    notifyListeners();
  }

  /// @brief Selects an instance page.
  void selectTab(InstanceTab tab) {
    selectedTab = tab;
    notifyListeners();
  }

  /// @brief Returns the configured game folder and whether it currently exists.
  String pathStatus() {
    final directory = config.gameDirectory();
    final message = Directory(directory).existsSync()
        ? 'Game folder exists. Play checks the selected executable.'
        : 'Game folder not found. Set your installation path in launcher settings.';
    return '$directory\n$message';
  }

  /// @brief Logs the saved directory in the console after settings change the game path.
  void refreshGameDirectory() {
    logWindow.appendMessage('Saved game directory: ${config.gameDirectory()}');
    statusMessage = 'Game path saved.';
    notifyListeners();
  }

  /// @brief Selects Console, validates the executable and SMAPI, and starts output capture.
  ///
  /// The game process is not tied to any page, so leaving the instance page does not stop
  /// it. Decoders keep partial UTF-8 sequences between chunks until the process exits.
  /// @return A warning for the page to show, or null when the launch was started or the
  /// failure only needed a console message.
  Future<LaunchWarning?> launchGame() async {
    // Select before validation so duplicate attempts and launch failures share the console.
    selectTab(InstanceTab.console);
    if (_processRunning) {
      logWindow.appendMessage('A game is already running from this launcher.', Severity.warn);
      return null;
    }
    final directory = config.gameDirectory();
    final isModded = _modded;
    if (isModded) {
      final smapi = const SmapiDetector().inspect(directory);
      if (!smapi.isInstalled) {
        final message = 'SMAPI is not installed or incomplete.\n${smapi.diagnostic}';
        logWindow.appendMessage(message, Severity.error);
        return LaunchWarning('Unable to launch SMAPI', message);
      }
    }

    final String binary;
    if (Platform.isWindows) {
      binary = isModded ? 'StardewModdingAPI.exe' : 'Stardew Valley.exe';
    } else if (Platform.isMacOS) {
      binary = isModded ? 'Contents/MacOS/StardewModdingAPI' : 'Contents/MacOS/StardewValley';
    } else {
      binary = isModded ? 'StardewModdingAPI' : 'StardewValley';
    }
    final executable = p.join(directory, binary);
    if (!isExecutableFile(executable)) {
      final message = 'Executable not found or not runnable:\n$executable';
      logWindow.appendMessage(message, Severity.error);
      return LaunchWarning('Unable to launch', '$message\n\nCheck your game path in Settings.');
    }

    final environment = <String, String>{};
    final arguments = <String>[];
    if (isModded) {
      environment['SMAPI_USE_CURRENT_SHELL'] = 'true';
      // SMAPI's supported developer output includes severity and trace records.
      // Ordinary console prefixes contain only the mod name, losing severity in pipes.
      arguments.add('--developer-mode');
    }

    logWindow.beginSession();
    logWindow.appendMessage('Launching $executable');
    final Process child;
    try {
      child = await Process.start(executable, arguments,
          workingDirectory: directory, environment: environment);
    } on ProcessException catch (error) {
      logWindow.flushOutput();
      logWindow.appendMessage('Game process: ${error.message}', Severity.error);
      selectTab(InstanceTab.console);
      return null;
    }
    _processRunning = true;
    logWindow.appendMessage('Started $executable');
    statusMessage = 'Game launched.';
    notifyListeners();

    // Keep UTF-8 decoding state across chunks; both channels feed the same console.
    final stdoutDone = _forwardLines(child.stdout);
    final stderrDone = _forwardLines(child.stderr);

    unawaited(child.exitCode.then((exitCode) async {
      // Drain remaining output before reporting the exit, like drainOutput() in Qt.
      await Future.wait([stdoutDone, stderrDone]).catchError((_) => <void>[]);
      _processRunning = false;
      // The page state may be gone while the game keeps running; nothing to update then.
      if (_disposed) return;
      logWindow.flushOutput();
      logWindow.appendMessage(
          'Game exited with code $exitCode.', exitCode == 0 ? Severity.info : Severity.error);
      if (exitCode != 0) selectTab(InstanceTab.console);
      notifyListeners();
    }));
    return null;
  }

  /// @brief Decodes one output stream and passes only complete lines to the console.
  ///
  /// Port note: QProcess::MergedChannels merged stdout and stderr in the OS, so the console
  /// saw one ordered stream. Dart reads the two pipes separately, so a partial stdout line
  /// could otherwise be joined with a stderr line. Each stream therefore keeps its own
  /// unfinished tail, and that tail is forwarded and flushed when the stream ends. Very long
  /// tails are forwarded early; the console splits them at its line-length limit.
  /// @return A future that completes after the stream closes and its tail is flushed.
  Future<void> _forwardLines(Stream<List<int>> output) {
    var tail = '';
    void forward(String text) {
      if (!_disposed) logWindow.appendOutput(text);
    }

    return output
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          tail += chunk;
          final lastLineEnd = tail.lastIndexOf(RegExp('[\r\n  ]'));
          if (lastLineEnd >= 0) {
            forward(tail.substring(0, lastLineEnd + 1));
            tail = tail.substring(lastLineEnd + 1);
          }
          if (tail.length >= maximumLineLength) {
            forward(tail);
            tail = '';
          }
        })
        .asFuture<void>()
        .whenComplete(() {
          if (tail.isEmpty || _disposed) return;
          forward(tail);
          logWindow.flushOutput();
        });
  }

  @override
  void dispose() {
    // The process keeps running; only our listeners go away (the Qt process outlived the UI).
    _disposed = true;
    logWindow.dispose();
    super.dispose();
  }
}

class InstanceWindow extends StatefulWidget {
  const InstanceWindow({super.key, required this.controller, this.onBackToLibrary});

  final InstanceWindowController controller;
  final VoidCallback? onBackToLibrary;

  @override
  State<InstanceWindow> createState() => _InstanceWindowState();
}

class _InstanceWindowState extends State<InstanceWindow> with SingleTickerProviderStateMixin {
  late final TabController _modTabs =
      TabController(length: 2, vsync: this, initialIndex: widget.controller.modViewIndex);

  InstanceWindowController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _modTabs.addListener(() {
      _controller.modViewIndex = _modTabs.index;
      // The Nexus tab loads lazily the first time it is selected.
      if (_modTabs.index == 1 && !_controller.modsLoaded) {
        setState(() => _controller.modsLoaded = true);
      }
    });
  }

  @override
  void dispose() {
    _modTabs.dispose();
    super.dispose();
  }

  Future<void> _launchGame() async {
    final warning = await _controller.launchGame();
    if (warning == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(warning.title),
        content: Text(warning.message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Scaffold(
        key: const ValueKey('instanceWindow'),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              TextButton(
                key: const ValueKey('backToLibrary'),
                onPressed: widget.onBackToLibrary,
                child: const Text('←  Library'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(_controller.name,
                    key: const ValueKey('detailTitle'), style: LauncherText.detailTitle),
              ),
              FilledButton(
                key: const ValueKey('playDetailInstance'),
                onPressed: _launchGame,
                child: const Text('▶  Play instance'),
              ),
            ]),
            const SizedBox(height: 16),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _buildNavigation(),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: LauncherColors.panel,
                      border: Border.all(color: LauncherColors.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    // IndexedStack keeps every page alive, like QStackedWidget.
                    child: IndexedStack(index: _controller.selectedTab.index, children: [
                      _buildModsPage(),
                      LogWindow(controller: _controller.logWindow),
                      _buildSettingsPage(),
                      _buildModpacksPage(),
                    ]),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        bottomNavigationBar: Container(
          color: LauncherColors.statusBar,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(_controller.statusMessage, key: const ValueKey('instanceStatus')),
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    const labels = ['Mods', 'Console', 'Settings', 'Modpacks'];
    // Keep the sidebar compact so both mod panes fit at the minimum window size.
    return SizedBox(
      width: 120,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('INSTANCE', style: LauncherText.eyebrow),
        const SizedBox(height: 8),
        for (final tab in InstanceTab.values)
          ListTile(
            key: ValueKey('navigation-${tab.name}'),
            dense: true,
            title: Text(labels[tab.index]),
            selected: _controller.selectedTab == tab,
            selectedColor: Colors.white,
            selectedTileColor: LauncherColors.accent,
            onTap: () => _controller.selectTab(tab),
          ),
      ]),
    );
  }

  Widget _buildModsPage() {
    return Column(children: [
      TabBar(
        key: const ValueKey('modViews'),
        controller: _modTabs,
        labelColor: LauncherColors.accentText,
        indicatorColor: LauncherColors.action,
        tabs: const [Tab(text: 'Installed'), Tab(text: 'Browse Nexus')],
      ),
      Expanded(
        child: TabBarView(controller: _modTabs, children: [
          ModInstallPage(
            config: _controller.config,
            onActivity: (message) => _controller.logWindow.appendMessage(message),
          ),
          _controller.modsLoaded
              ? const NexusPage(showBack: false)
              : const Center(child: Text('Select this tab to load Nexus mods.')),
        ]),
      ),
    ]);
  }

  Widget _buildSettingsPage() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text('Instance settings', style: LauncherText.sectionTitle),
        const Text('Choose how you return to the valley.'),
        const SizedBox(height: 16),
        Row(children: [
          const SizedBox(width: 130, child: Text('Launch mode')),
          DropdownButton<bool>(
            key: const ValueKey('launchMode'),
            value: _controller.modded,
            items: const [
              DropdownMenuItem(value: false, child: Text('Vanilla')),
              DropdownMenuItem(value: true, child: Text('Modded (SMAPI)')),
            ],
            onChanged: (value) {
              if (value != null) _controller.setLaunchMode(value);
            },
          ),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(width: 130, child: Text('Game directory')),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              OutlinedButton(
                key: const ValueKey('openSettings'),
                onPressed: _controller.settingsRequested,
                child: const Text('Open launcher settings…'),
              ),
              const SizedBox(height: 8),
              Text(_controller.pathStatus(), key: const ValueKey('pathStatus')),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        const Text(
          'The game directory is shared by all instances. It starts with the Ubuntu Steam '
          'default; select a different location for other installations.',
          style: LauncherText.muted,
        ),
        const SizedBox(height: 24),
        const Text('SMAPI', style: LauncherText.sectionTitle),
        const Text('Modded mode launches an existing SMAPI installation. Automatic SMAPI '
            'installation is not connected in this UI build.'),
      ]),
    );
  }

  Widget _buildModpacksPage() {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Modpacks', style: LauncherText.sectionTitle),
        Text('Modpack management is coming in a future build.'),
      ]),
    );
  }
}
