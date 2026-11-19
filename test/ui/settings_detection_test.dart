// Port of tests/ui/SettingsDetectionTests.cpp.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/ui/game_directory_detector.dart';
import 'package:prismatic_launcher/ui/launcher_config.dart';
import 'package:prismatic_launcher/ui/settings.dart';

import '../smapi/smapi_fixture.dart' show temporaryDirectory;

/// @brief Creates the platform's game executable inside [path].
void createGame(String path) {
  final String executable;
  if (Platform.isWindows) {
    executable = 'Stardew Valley.exe';
  } else if (Platform.isMacOS) {
    executable = 'Contents/MacOS/StardewValley';
  } else {
    executable = 'StardewValley';
  }
  final file = File(p.join(path, executable));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(const []);
}

/// @brief Escapes a path for a Steam VDF string.
String vdfPath(String path) => path.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

void main() {
  late String temp;
  setUp(() => temp = temporaryDirectory(addTearDown).path);
  String path(String name) => p.join(temp, name);

  test('detectsDefaultSteamLibrary', () {
    final game = path('Steam/steamapps/common/Stardew Valley');
    createGame(game);
    expect(GameDirectoryDetector.withLocations([path('Steam')]).detect(), game);
  });

  test('prefersCurrentValidInstallation', () {
    final preferred = path('My Game');
    createGame(preferred);
    createGame(path('Steam/steamapps/common/Stardew Valley'));
    expect(GameDirectoryDetector.withLocations([path('Steam')]).detect(preferred), preferred);
  });

  for (final (row, legacy, manifest) in [
    ('modern', false, 'steamapps/libraryfolders.vdf'),
    ('legacy', true, 'steamapps/libraryfolders.vdf'),
    ('config-copy', false, 'config/libraryfolders.vdf'),
  ]) {
    test('detectsAdditionalSteamLibrary ($row)', () {
      final steam = path('Steam');
      final library = path('Extra Library é');
      final game = p.join(library, 'steamapps/common/Stardew Valley');
      createGame(game);
      final entry = legacy ? '"1" "${vdfPath(library)}"' : '"1" { "path" "${vdfPath(library)}" }';
      final file = File(p.join(steam, manifest))..parent.createSync(recursive: true);
      file.writeAsStringSync('"libraryfolders" { $entry }');
      expect(GameDirectoryDetector.withLocations([steam]).detect(), game);
    });
  }

  test('skipsMissingAndInvalidCandidates', () {
    final game = path('GOG Game');
    createGame(game);
    final detector = GameDirectoryDetector.withLocations([path('Missing Steam')], [temp, game]);
    expect(detector.detect(path('Missing Game')), game);
    expect(GameDirectoryDetector.withLocations([], [temp]).detect(), isEmpty);
    expect(GameDirectoryDetector.withLocations([], ['relative/game', '']).detect(' '), isEmpty);
  });

  test('ignoresMalformedOrOversizedLibraryList', () {
    Directory(path('steamapps')).createSync();
    final manifest = File(path('steamapps/libraryfolders.vdf'));
    final detector = GameDirectoryDetector.withLocations([temp]);
    manifest.writeAsStringSync('"path" "relative/library"\nmalformed');
    expect(detector.detect(), isEmpty);
    manifest.writeAsStringSync('x' * (1024 * 1024 + 1));
    expect(detector.detect(), isEmpty);
  });

  test('normalizesMacExecutableDirectoryToBundleRoot', () {
    final game = path('Stardew Valley.app');
    createGame(game);
    expect(GameDirectoryDetector.withLocations([]).detect('$game/Contents/MacOS'), game);
  }, skip: !Platform.isMacOS);

  testWidgets('detectButtonFillsPathWithoutSaving', (tester) async {
    final game = path('Steam/steamapps/common/Stardew Valley');
    createGame(game);
    final config = LauncherConfig(path('launcher.ini'));
    final saved = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Settings(
        config: config,
        detector: GameDirectoryDetector.withLocations([path('Steam')]),
        onGameDirectoryChanged: saved.add,
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('detectDirectory')));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('gameDirectoryValue')));
    expect(field.controller!.text, game);
    expect(find.textContaining('Detected game directory'), findsOneWidget);
    expect(File(config.filePath()).existsSync(), isFalse);
    expect(saved, isEmpty);

    await tester.tap(find.byKey(const ValueKey('savePath')));
    await tester.pump();
    expect(config.gameDirectory(), game);
    expect(saved, hasLength(1));
  });

  testWidgets('failedDetectionKeepsPathAndSettings', (tester) async {
    final config = LauncherConfig(path('launcher.ini'));
    expect(config.saveGameDirectory(temp), isTrue);
    await tester.pumpWidget(MaterialApp(
      home: Settings(config: config, detector: GameDirectoryDetector.withLocations([])),
    ));
    await tester.enterText(find.byKey(const ValueKey('gameDirectoryValue')), path('unsaved'));
    await tester.tap(find.byKey(const ValueKey('detectDirectory')));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('gameDirectoryValue')));
    expect(field.controller!.text, path('unsaved'));
    expect(config.gameDirectory(), temp);
    expect(find.textContaining('Could not detect'), findsOneWidget);
  });
}
