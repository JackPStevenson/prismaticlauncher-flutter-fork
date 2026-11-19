// Port of src/qt/ChickPixDialog.{h,cpp}.
//
// Modal editor for the ChickPix artwork: image choice, visibility, and opacity, with a
// preview that only affects the library after Save.

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'chick_pix_images.dart';
import 'launcher_config.dart';
import 'style.dart';

class ChickPixDialog extends StatefulWidget {
  const ChickPixDialog({super.key, required this.config, this.onSaved});

  final LauncherConfig config;
  // Replaces the Qt `saved` signal: called after all three values synced to the INI.
  final VoidCallback? onSaved;

  /// @brief Opens the dialog modally.
  static Future<void> show(BuildContext context, LauncherConfig config, {VoidCallback? onSaved}) =>
      showDialog<void>(
        context: context,
        builder: (_) => ChickPixDialog(config: config, onSaved: onSaved),
      );

  @override
  State<ChickPixDialog> createState() => ChickPixDialogState();
}

class ChickPixDialogState extends State<ChickPixDialog> {
  late final ChickPixImages _images = ChickPixImages(widget.config.filePath());
  List<String> _catalog = [];
  String _selection = '';
  int _opacity = 75;
  bool _enabled = true;
  String _status = '';
  ChickPixImage? _previewSource;

  @override
  void initState() {
    super.initState();
    reload();
    _initialized = true;
  }

  // setState() may not be called during initState, which runs reload() once.
  bool _initialized = false;
  void _apply(VoidCallback update) => _initialized ? setState(update) : update();

  /// @brief Discards pending edits and reloads the saved settings and image catalog.
  void reload() {
    _selection = widget.config.farmPackImage();
    _opacity = widget.config.farmPackOpacityPercent();
    _enabled = widget.config.farmPackEnabled();
    _refreshCatalog();
  }

  /// @brief Lists unique image filenames and resolves the pending choice to its retained
  /// entry.
  void _refreshCatalog() {
    final catalog = _images.catalog();
    final selection = _images.resolveSelection(_selection, catalog);
    // An unavailable saved selection stays listed so it is not silently replaced.
    if (!catalog.contains(selection)) catalog.add(selection);
    _apply(() {
      _catalog = catalog;
      _selection = selection;
    });
    _loadPreview();
  }

  /// @brief Decodes the pending image or Default fallback and refreshes its preview.
  void _loadPreview() {
    var image = _selection.isEmpty ? null : _images.load(_selection);
    final String status;
    if (_selection.isNotEmpty && image == null) {
      status = 'Selected image is unavailable or invalid. Using Default artwork. '
          'The saved selection is retained until you save another image.';
    } else {
      status = 'Preview only. Select Save to apply changes to the library.';
    }
    image ??= _images.load(ChickPixImages.defaultImage());
    _apply(() {
      _status = status;
      _previewSource = image;
    });
  }

  /// @brief Saves pending values and reports failures without announcing success.
  void _save() {
    if (!widget.config.saveChickPix(_selection, _opacity, _enabled)) {
      _apply(() => _status =
          'Could not save ChickPix settings. Check that the settings location is writable.');
      return;
    }
    _loadPreview();
    if (_selection.isEmpty || _images.load(_selection) != null) {
      _apply(() => _status = 'Saved ChickPix settings.');
    } else {
      _apply(() => _status = 'Saved ChickPix settings. $_status');
    }
    widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _previewSource;
    return AlertDialog(
      key: const ValueKey('chickPixDialog'),
      title: const Text('Configure ChickPix'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const SizedBox(width: 80, child: Text('Image')),
                Expanded(
                  child: DropdownButton<String>(
                    key: const ValueKey('chickPixImage'),
                    isExpanded: true,
                    value: _catalog.contains(_selection) ? _selection : null,
                    items: [
                      for (final path in _catalog)
                        DropdownMenuItem(
                            value: path,
                            child: Tooltip(message: path, child: Text(p.basename(path)))),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _apply(() => _selection = value);
                      _loadPreview();
                    },
                  ),
                ),
              ]),
              CheckboxListTile(
                key: const ValueKey('chickPixEnabled'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Show ChickPix artwork'),
                value: _enabled,
                onChanged: (value) => _apply(() => _enabled = value ?? false),
              ),
              Row(children: [
                const SizedBox(width: 80, child: Text('Opacity')),
                Expanded(
                  child: Slider(
                    key: const ValueKey('chickPixOpacity'),
                    value: _opacity.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 100,
                    semanticFormatterCallback: (value) =>
                        'ChickPix opacity percentage ${value.round()}',
                    onChanged: (value) => _apply(() => _opacity = value.round()),
                  ),
                ),
                SizedBox(width: 48, child: Text('$_opacity%')),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                key: const ValueKey('chickPixPreview'),
                height: 180,
                child: (_enabled && preview != null)
                    ? Opacity(
                        opacity: _opacity / 100,
                        child:
                            Image.memory(preview.bytes, fit: BoxFit.contain, gaplessPlayback: true),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 16),
              SelectableText(
                'Custom image folders:\n${_images.folders().join('\n')}',
                key: const ValueKey('chickPixFolders'),
                style: LauncherText.muted,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const ValueKey('chickPixRefresh'),
                  onPressed: _refreshCatalog,
                  child: const Text('Refresh images'),
                ),
              ),
              const SizedBox(height: 8),
              Text(_status, key: const ValueKey('chickPixStatus')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
            key: const ValueKey('chickPixSave'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
