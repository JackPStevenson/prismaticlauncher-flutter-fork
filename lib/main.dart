// Port of src/qt/main.cpp.

import 'dart:io';

import 'package:args/args.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'ui/chick_pix_images.dart';
import 'ui/launcher_config.dart';
import 'ui/launcher_window.dart';
import 'ui/style.dart';

/// @brief Returns the default launcher.ini path.
///
/// This matches QStandardPaths::AppConfigLocation for organization "Prismatic" and
/// application "Prismatic Launcher", so the Qt and Flutter builds share one settings file.
String defaultConfigFile() {
  final home = LauncherConfig.homePath();
  final String configRoot;
  if (Platform.isWindows) {
    configRoot = Platform.environment['APPDATA'] ?? p.join(home, 'AppData', 'Roaming');
  } else if (Platform.isMacOS) {
    configRoot = p.join(home, 'Library', 'Preferences');
  } else {
    configRoot = Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
  }
  return p.join(configRoot, 'Prismatic', 'Prismatic Launcher', 'launcher.ini');
}

/// @brief Parses `--config <file>`, loads bundled artwork, and shows the launcher.
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  final parser = ArgParser()
    ..addOption('config', help: 'Use an alternate INI configuration file.', valueHelp: 'file')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Displays help on commandline options.');
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(1);
  }
  if (options.flag('help')) {
    stdout
      ..writeln('Prismatic Launcher — Stardew Valley launcher UI')
      ..writeln(parser.usage);
    exit(0);
  }

  final configOption = options.option('config');
  final configFile = configOption != null ? p.absolute(configOption) : defaultConfigFile();

  // Flutter assets load asynchronously; ChickPix needs its bundled images before first build.
  await ChickPixImages.preloadBundledImages();
  runApp(PrismaticLauncherApp(configFile: configFile));
}

class PrismaticLauncherApp extends StatelessWidget {
  const PrismaticLauncherApp({super.key, required this.configFile});

  final String configFile;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Prismatic Launcher',
      debugShowCheckedModeBanner: false,
      theme: buildLauncherTheme(),
      home: LauncherWindow(configFile: configFile),
    );
  }
}
