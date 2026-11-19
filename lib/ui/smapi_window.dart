// Port of src/qt/SmapiWindow.{h,cpp,ui}.
//
// Port note: the Qt QDialog stayed alive between openings. A Flutter dialog is rebuilt each
// time it opens, which is equivalent because refresh() re-inspected SMAPI on every open.

import 'package:material_ui/material_ui.dart';

import '../smapi/smapi_detector.dart';

/// @brief Returns the status text shown for an inspected SMAPI installation.
String smapiStatusText(SmapiInstallation installation) {
  var status = switch (installation.state) {
    SmapiState.invalidGamePath => 'Game directory not found',
    SmapiState.notInstalled => 'SMAPI is not installed',
    SmapiState.installed =>
      'SMAPI installed\nVersion ${installation.version?.toString() ?? 'unknown'}',
    SmapiState.incomplete => 'SMAPI installation is incomplete',
    SmapiState.componentMismatch => 'SMAPI components have mismatched versions',
    SmapiState.unreadable => 'SMAPI files could not be read',
  };
  if (installation.state != SmapiState.installed &&
      installation.state != SmapiState.notInstalled &&
      installation.diagnostic.isNotEmpty) {
    status += '\n${installation.diagnostic}';
  }
  return status;
}

class SmapiWindow extends StatelessWidget {
  const SmapiWindow({super.key, required this.gameDirectory});

  final String gameDirectory;

  /// @brief Opens the SMAPI settings dialog for [gameDirectory].
  static Future<void> show(BuildContext context, String gameDirectory) => showDialog<void>(
        context: context,
        builder: (_) => SmapiWindow(gameDirectory: gameDirectory),
      );

  @override
  Widget build(BuildContext context) {
    final installation = const SmapiDetector().inspect(gameDirectory);
    return AlertDialog(
      key: const ValueKey('smapiWindow'),
      title: const Text('SMAPI Settings'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('resources/SMAPI_mascot.png', width: 82, height: 82),
          const SizedBox(height: 16),
          Text(smapiStatusText(installation),
              key: const ValueKey('stateLabel'), textAlign: TextAlign.center),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
