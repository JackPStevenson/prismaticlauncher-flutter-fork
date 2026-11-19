// Port of src/qt/LauncherWindow.{h,cpp,ui} and src/qt/AddInstanceDialog.ui.
//
// Port notes:
// - Qt opened InstanceWindow, settings, and SmapiWindow as extra top-level windows. This
//   Flutter app has one window: instance and settings are pushed routes; SMAPI and
//   Add Instance are dialogs. The library and Nexus browser are pages of an IndexedStack,
//   replacing the QStackedWidget.
// - The ChickPix overlay is a Positioned image inside a Stack. Its size follows the same
//   rules as refreshFarmPackOverlay() (30% width clamped to 220–420, at least 220 tall).
// - The painted landscape icon (instanceIcon) is drawn with a CustomPainter.

import 'package:material_ui/material_ui.dart';

import 'chick_pix_images.dart';
import 'instance_window.dart';
import 'launcher_config.dart';
import 'nexus_page.dart';
import 'settings.dart';
import 'smapi_window.dart';
import 'style.dart';

const double instanceWidth = 146;
const double instanceHeight = 162;

/// @brief One library entry (QListWidgetItem with UserRole data in the Qt code).
class LauncherInstance {
  LauncherInstance(this.name, this.modded);
  final String name;
  bool modded;

  String get label => '$name\n${modded ? 'Modded' : 'Vanilla'}';
}

class LauncherWindow extends StatefulWidget {
  /// @brief Builds the launcher and applies saved ChickPix artwork and quick-control values.
  const LauncherWindow({super.key, required this.configFile});

  final String configFile;

  @override
  State<LauncherWindow> createState() => LauncherWindowState();
}

class LauncherWindowState extends State<LauncherWindow> {
  late final LauncherConfig config = LauncherConfig(widget.configFile);
  final List<LauncherInstance> _instances = [LauncherInstance('Stardew Valley', false)];
  final TextEditingController _instanceSearch = TextEditingController();
  int? _currentIndex = 0;
  int _page = 0; // 0 = library, 1 = Nexus browser.
  bool _nexusOpened = false;
  String _status = 'Local launcher  /  UI preview';

  ChickPixImage? _farmPackImage;
  bool _farmPackEnabled = false;
  double _farmPackOpacity = 0.75;

  InstanceWindowController? _instanceWindow;

  @override
  void initState() {
    super.initState();
    reloadChickPix();
  }

  @override
  void dispose() {
    _instanceSearch.dispose();
    _instanceWindow?.dispose();
    super.dispose();
  }

  void _showStatus(String message) => setState(() => _status = message);

  /// @brief Loads the saved image or Default fallback and synchronizes the ChickPix toggle.
  void reloadChickPix() {
    final images = ChickPixImages(config.filePath());
    final selection = images.resolveSelection(config.farmPackImage(), images.catalog());
    final image = images.load(selection) ?? images.load(ChickPixImages.defaultImage());
    void apply() {
      _farmPackImage = image;
      _farmPackEnabled = config.farmPackEnabled();
      _farmPackOpacity = config.farmPackOpacityPercent() / 100;
    }

    mounted ? setState(apply) : apply();
  }

  bool get _farmPackLoaded => _farmPackImage != null;

  void _toggleFarmPack(bool enabled) {
    if (!config.saveFarmPackEnabled(enabled)) {
      _showStatus('Could not save ChickPix setting.');
      return;
    }
    setState(() => _farmPackEnabled = enabled);
    _showStatus(enabled ? 'ChickPix artwork enabled.' : 'ChickPix artwork disabled.');
  }

  List<int> _visibleIndexes() {
    final query = _instanceSearch.text.toLowerCase();
    return [
      for (var index = 0; index < _instances.length; ++index)
        if (_instances[index].label.toLowerCase().contains(query)) index,
    ];
  }

  LauncherInstance? _currentVisibleInstance() {
    final current = _currentIndex;
    if (current == null || !_visibleIndexes().contains(current)) return null;
    return _instances[current];
  }

  Future<void> _addInstance() async {
    final created = await showDialog<LauncherInstance>(
      context: context,
      builder: (_) => const AddInstanceDialog(),
    );
    if (created == null) return;
    setState(() {
      _instances.add(created);
      _instanceSearch.clear();
      _currentIndex = _instances.length - 1;
    });
    await openInstanceWindow();
  }

  /// @brief Opens the selected instance page, reusing its state between openings.
  Future<void> openInstanceWindow([InstanceTab tab = InstanceTab.mods, bool launch = false]) async {
    final instance = _currentVisibleInstance();
    if (instance == null) {
      _showStatus('Select an instance first.');
      return;
    }

    var controller = _instanceWindow;
    if (controller == null) {
      controller = InstanceWindowController(instance.name, instance.modded, config);
      controller
        ..settingsRequested = openSettingsWindow
        ..launchModeChanged = (enabled) {
          final current = _currentVisibleInstance();
          if (current != null) setState(() => current.modded = enabled);
        };
      _instanceWindow = controller;
    } else {
      controller.setInstance(instance.name, instance.modded);
    }
    controller.selectTab(tab);
    if (launch) {
      // Start launching first so the console is selected when the page appears.
      unawaitedLaunch(controller);
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (routeContext) => InstanceWindow(
        controller: controller!,
        onBackToLibrary: () => Navigator.of(routeContext).pop(),
      ),
    ));
  }

  /// @brief Launches without waiting; warnings are logged to the console by the controller.
  void unawaitedLaunch(InstanceWindowController controller) {
    controller.launchGame().then((warning) {
      if (warning == null || !mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(warning.title),
          content: Text(warning.message),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
          ],
        ),
      );
    });
  }

  /// @brief Shows launcher settings and applies successful ChickPix saves to the library.
  Future<void> openSettingsWindow() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (routeContext) => Settings(
        config: config,
        onChickPixChanged: reloadChickPix,
        onGameDirectoryChanged: (_) {
          _instanceWindow?.refreshGameDirectory();
          _showStatus('Game path saved.');
        },
        // "← Library" returns all the way to the launcher, closing any instance page.
        onBackToLibraryRequested: () =>
            Navigator.of(routeContext).popUntil((route) => route.isFirst),
      ),
    ));
  }

  /// @brief Opens the selected instance and launches it with live console capture.
  void _launchGame() {
    if (_currentVisibleInstance() == null) {
      _showStatus('Select an instance first.');
      return;
    }
    openInstanceWindow(InstanceTab.console, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _page, children: [
        _buildLibrary(),
        if (_nexusOpened)
          NexusPage(onBackRequested: () => setState(() => _page = 0))
        else
          const SizedBox.shrink(),
      ]),
      bottomNavigationBar: Container(
        color: LauncherColors.statusBar,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(_status, key: const ValueKey('statusBar')),
      ),
    );
  }

  Widget _buildLibrary() {
    final visible = _visibleIndexes();
    return LayoutBuilder(builder: (context, constraints) {
      final overlayWidth = (constraints.maxWidth * 0.30).clamp(220.0, 420.0);
      final overlayHeight = (constraints.maxHeight * 0.55).clamp(220.0, double.infinity);
      return Stack(key: const ValueKey('centralWidget'), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _buildToolbar(),
            const Divider(),
            Expanded(
              child: Container(
                color: LauncherColors.panel,
                padding: const EdgeInsets.all(8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final index in visible) _buildInstanceTile(index),
                ]),
              ),
            ),
          ]),
        ),
        if (_farmPackLoaded && _farmPackEnabled)
          Positioned(
            right: 20,
            bottom: 20,
            child: IgnorePointer(
              child: Opacity(
                key: const ValueKey('farmPackOverlay'),
                opacity: _farmPackOpacity,
                child: SizedBox(
                  width: overlayWidth,
                  height: overlayHeight,
                  child: Image.memory(_farmPackImage!.bytes,
                      fit: BoxFit.contain, alignment: Alignment.bottomRight, gaplessPlayback: true),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  Widget _buildToolbar() {
    return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton(
              key: const ValueKey('addInstance'),
              onPressed: _addInstance,
              child: const Text('+  Add')),
          FilledButton(
              key: const ValueKey('playInstance'),
              onPressed: _launchGame,
              child: const Text('▶  Play')),
          OutlinedButton(
              key: const ValueKey('editInstance'),
              onPressed: () => openInstanceWindow(),
              child: const Text('✐ Edit')),
          OutlinedButton(
            key: const ValueKey('browseNexusMods'),
            onPressed: () => setState(() {
              _nexusOpened = true;
              _page = 1;
            }),
            child: const Text('Browse Nexus mods'),
          ),
          Tooltip(
            message: 'Toggle ChickPix artwork',
            child: FilterChip(
              key: const ValueKey('farmPackToggle'),
              label: const Text('ChickPix'),
              selected: _farmPackEnabled,
              onSelected: _farmPackLoaded ? _toggleFarmPack : null,
            ),
          ),
          SizedBox(
            width: 220,
            child: TextField(
              key: const ValueKey('instanceSearch'),
              controller: _instanceSearch,
              decoration: const InputDecoration(hintText: 'Search instances…'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          OutlinedButton(
            key: const ValueKey('smapi'),
            onPressed: () => SmapiWindow.show(context, config.gameDirectory()),
            child: const Text('Configure SMAPI'),
          ),
          Tooltip(
            message: 'Launcher settings',
            child: IconButton(
              key: const ValueKey('settings'),
              onPressed: openSettingsWindow,
              icon: Image.asset('resources/cogwheel.png', width: 20, height: 20),
            ),
          ),
        ]);
  }

  Widget _buildInstanceTile(int index) {
    final instance = _instances[index];
    final selected = index == _currentIndex;
    return GestureDetector(
      key: ValueKey('instance-$index'),
      onTap: () => setState(() => _currentIndex = index),
      onDoubleTap: () {
        setState(() => _currentIndex = index);
        openInstanceWindow();
      },
      child: Container(
        width: instanceWidth,
        height: instanceHeight,
        decoration: BoxDecoration(
          color: selected ? LauncherColors.accentSoft : LauncherColors.panel,
          border: Border.all(color: selected ? LauncherColors.accent : Colors.transparent),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(children: [
          const SizedBox(width: 82, height: 82, child: CustomPaint(painter: InstanceIconPainter())),
          const SizedBox(height: 6),
          Text(instance.label,
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: selected ? LauncherColors.accentText : const Color(0xFF41474B))),
        ]),
      ),
    );
  }
}

/// @brief Draws the default instance art: sun, two hills, and a small farmhouse.
///
/// Coordinates are the original 160×160 QPainter coordinates, scaled to the widget size.
class InstanceIconPainter extends CustomPainter {
  const InstanceIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 160, size.height / 160);
    Paint fill(int color) => Paint()..color = Color(color);
    Path polygon(List<Offset> points) => Path()..addPolygon(points, true);

    canvas.drawRect(const Rect.fromLTWH(0, 0, 160, 160), fill(0xFF253E39));
    canvas.drawOval(const Rect.fromLTWH(75, 32, 40, 40), fill(0xFF72C7AB));
    canvas.drawPath(
        polygon(const [Offset(0, 115), Offset(55, 60), Offset(110, 115)]), fill(0xFF3C6655));
    canvas.drawPath(
        polygon(const [Offset(55, 140), Offset(120, 65), Offset(180, 140)]), fill(0xFF527B5F));
    canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(48, 101, 40, 32), const Radius.circular(2)),
        fill(0xFFD8C495));
    canvas.drawPath(
        polygon(const [Offset(40, 102), Offset(68, 78), Offset(96, 102)]), fill(0xFFB97656));
    canvas.drawRect(const Rect.fromLTWH(64, 113, 10, 20), fill(0xFF253E39));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// @brief Port of AddInstanceDialog.ui: name and launch mode for a new session instance.
class AddInstanceDialog extends StatefulWidget {
  const AddInstanceDialog({super.key});

  @override
  State<AddInstanceDialog> createState() => _AddInstanceDialogState();
}

class _AddInstanceDialogState extends State<AddInstanceDialog> {
  final TextEditingController _name = TextEditingController(text: 'My Stardew Valley');
  bool _modded = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = _name.text.trim().isNotEmpty;
    return AlertDialog(
      key: const ValueKey('addInstanceDialog'),
      title: const Text('Add instance'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('name'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<bool>(
            key: const ValueKey('mode'),
            isExpanded: true,
            initialValue: _modded,
            decoration: const InputDecoration(labelText: 'Launch mode'),
            items: const [
              DropdownMenuItem(value: false, child: Text('Vanilla')),
              DropdownMenuItem(value: true, child: Text('Modded (requires installed SMAPI)')),
            ],
            onChanged: (value) => setState(() => _modded = value ?? false),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('createInstance'),
          onPressed: canCreate
              ? () => Navigator.of(context).pop(LauncherInstance(_name.text.trim(), _modded))
              : null,
          child: const Text('Create instance'),
        ),
      ],
    );
  }
}
