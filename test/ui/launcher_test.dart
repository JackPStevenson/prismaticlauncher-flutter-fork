// Port of the configuration, library, and ChickPix scenarios from tests/ui/LauncherTests.cpp
// and tests/ui/ChickPixTests.cpp.
//
// Port note: Qt tests inspected widgets with findChild<...>("objectName"). Flutter tests find
// widgets by ValueKey, using the same names wherever the Qt object had one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/ui/chick_pix_images.dart';
import 'package:prismatic_launcher/ui/launcher_config.dart';
import 'package:prismatic_launcher/ui/launcher_window.dart';
import 'package:prismatic_launcher/ui/style.dart';

import '../smapi/smapi_fixture.dart' show temporaryDirectory;

final String defaultGamePath =
    '${LauncherConfig.homePath()}/.local/share/Steam/steamapps/common/Stardew Valley';

/// @brief Creates a distinctive opaque PNG without using game or user artwork.
void writeChicken(String path,
    {int red = 23, int green = 187, int blue = 109, int width = 32, int height = 24}) {
  final image = img.Image(width: width, height: height)..clear(img.ColorRgb8(red, green, blue));
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(image));
}

/// @brief Pumps the launcher in a desktop-sized window.
Future<void> pumpLauncher(WidgetTester tester, String configFile) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildLauncherTheme(),
    home: LauncherWindow(configFile: configFile),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ChickPixImages.preloadBundledImages);

  late String temp;
  setUp(() => temp = temporaryDirectory(addTearDown).path);
  String path(String name) => p.join(temp, name);

  group('LauncherConfig', () {
    test('defaultPath', () {
      final config = LauncherConfig(path('launcher.ini'));
      expect(config.gameDirectory(), defaultGamePath);
      expect(File(config.filePath()).existsSync(), isFalse);
      expect(config.farmPackEnabled(), isTrue);
    });

    test('persistPath', () {
      final file = path('nested/launcher.ini');
      final config = LauncherConfig(file);
      expect(config.saveGameDirectory('   '), isFalse);
      expect(config.saveGameDirectory('relative/game'), isFalse);
      expect(config.saveGameDirectory(path('Game with spaces')), isTrue);
      expect(LauncherConfig(file).gameDirectory(), path('Game with spaces'));
      expect(LauncherConfig.expandHome('~/Games'), '${LauncherConfig.homePath()}/Games');
    });

    test('persistFarmPackToggle', () {
      final config = LauncherConfig(path('launcher.ini'));
      expect(config.saveFarmPackEnabled(false), isTrue);
      expect(LauncherConfig(config.filePath()).farmPackEnabled(), isFalse);
      expect(config.saveFarmPackEnabled(true), isTrue);
      expect(LauncherConfig(config.filePath()).farmPackEnabled(), isTrue);
    });

    test('persistFarmPackOpacity', () {
      final config = LauncherConfig(path('launcher.ini'));
      expect(config.farmPackOpacityPercent(), 75);
      expect(config.saveFarmPackOpacityPercent(42), isTrue);
      expect(LauncherConfig(config.filePath()).farmPackOpacityPercent(), 42);
      expect(config.saveFarmPackOpacityPercent(101), isFalse);
    });

    test('invalidConfigDoesNotUseWorkingDirectory', () {
      final file = path('launcher.ini');
      File(file).writeAsStringSync('[game]\ndirectory=relative/game\n');
      expect(LauncherConfig(file).gameDirectory(), defaultGamePath);
    });

    test('readsQtWrittenIniFile', () {
      // A file in the layout QSettings writes, including a quoted value and a comment.
      final file = path('launcher.ini');
      File(file).writeAsStringSync('; written by Qt\n[appearance]\nfarm-pack-enabled=false\n'
          'farm-pack-opacity=30\nfarm-pack-image=":/farmpack/spring.png"\n\n'
          '[game]\ndirectory=${path('Game')}\n');
      final config = LauncherConfig(file);
      expect(config.farmPackEnabled(), isFalse);
      expect(config.farmPackOpacityPercent(), 30);
      expect(config.farmPackImage(), ':/farmpack/spring.png');
      expect(config.gameDirectory(), path('Game'));
    });

    test('blockedConfigSaveReportsFailure', () {
      // A directory where the INI file should be makes every write fail.
      Directory(path('launcher.ini')).createSync();
      final config = LauncherConfig(path('launcher.ini'));
      expect(config.saveChickPix(':/farmpack/spring.png', 40, false), isFalse);
      expect(config.saveGameDirectory(temp), isFalse);
    });
  });

  group('ChickPixImages', () {
    test('imageChoicesExcludeInvalidOversizedAndEscapingFiles', () {
      final custom = path('chickens/My hen é.png');
      final unsupported = path('chickens/unsupported.txt');
      final corrupt = path('chickens/corrupt.png');
      final oversized = path('chickens/oversized.png');
      final tooWide = path('chickens/too-wide.png');
      final outside = path('outside.png');
      final escaped = path('chickens/escaped.png');
      writeChicken(custom);
      writeChicken(unsupported);
      writeChicken(outside);
      writeChicken(oversized);
      // A narrow strip exceeds the dimension limit while using little memory.
      writeChicken(tooWide, width: 16384, height: 1);
      // A sparse file exercises the encoded-size limit without allocating a giant image.
      File(oversized).openSync(mode: FileMode.append)
        ..truncateSync(1024 * 1024 * 1024)
        ..closeSync();
      File(corrupt).writeAsStringSync('not an image');
      if (!Platform.isWindows) Link(escaped).createSync(outside);

      final catalog = ChickPixImages(path('launcher.ini')).catalog();
      final names = catalog.map((entry) => p.basename(entry).toLowerCase()).toList();
      expect(names.toSet(), hasLength(names.length));
      for (final bundled in bundledImages) {
        expect(catalog, contains(bundled));
      }
      expect(catalog, contains(custom));
      for (final excluded in [unsupported, corrupt, oversized, tooWide, escaped]) {
        expect(catalog, isNot(contains(excluded)));
      }
    });

    test('savedDuplicateSelectsExistingRepresentative', () {
      // Identical pixels under a different name resolve to the first catalog entry.
      writeChicken(path('chickens/first.png'), red: 200);
      writeChicken(path('chickens/second-copy.png'), red: 200);
      final images = ChickPixImages(path('launcher.ini'));
      final catalog = images.catalog();
      expect(catalog, contains(path('chickens/first.png')));
      expect(catalog, isNot(contains(path('chickens/second-copy.png'))));
      expect(images.resolveSelection(path('chickens/second-copy.png'), catalog),
          path('chickens/first.png'));
    });

    test('legacyEmptyImageUsesDefault', () {
      final images = ChickPixImages(path('launcher.ini'));
      expect(images.resolveSelection('', images.catalog()), ChickPixImages.defaultImage());
      expect(images.load(ChickPixImages.defaultImage()), isNotNull);
    });
  });

  group('LauncherWindow', () {
    testWidgets('startupRendersSavedArtworkAndToggleIsPersistent', (tester) async {
      final config = LauncherConfig(path('launcher.ini'));
      await pumpLauncher(tester, config.filePath());
      expect(find.byKey(const ValueKey('farmPackOverlay')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('farmPackToggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('farmPackOverlay')), findsNothing);
      expect(LauncherConfig(config.filePath()).farmPackEnabled(), isFalse);
      expect(find.text('ChickPix artwork disabled.'), findsOneWidget);
    });

    testWidgets('createSessionInstanceAndFilter', (tester) async {
      await pumpLauncher(tester, path('launcher.ini'));
      await tester.tap(find.byKey(const ValueKey('addInstance')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('name')), 'Second Farm');
      await tester.tap(find.byKey(const ValueKey('createInstance')));
      await tester.pumpAndSettle();
      // Creating an instance opens its page, like the Qt dialog flow.
      expect(find.byKey(const ValueKey('instanceWindow')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('backToLibrary')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Second Farm'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('instanceSearch')), 'second');
      await tester.pump();
      expect(find.textContaining('Stardew Valley\nVanilla'), findsNothing);
      expect(find.textContaining('Second Farm'), findsOneWidget);
    });

    testWidgets('instanceWindowUpdatesLibraryMode', (tester) async {
      await pumpLauncher(tester, path('launcher.ini'));
      await tester.tap(find.byKey(const ValueKey('editInstance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('navigation-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('launchMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modded (SMAPI)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backToLibrary')));
      await tester.pumpAndSettle();
      expect(find.text('Stardew Valley\nModded'), findsOneWidget);
    });

    testWidgets('smapiButtonOpensSmapiWindow', (tester) async {
      final config = LauncherConfig(path('launcher.ini'));
      expect(config.saveGameDirectory(temp), isTrue);
      await pumpLauncher(tester, config.filePath());
      await tester.tap(find.byKey(const ValueKey('smapi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('smapiWindow')), findsOneWidget);
      expect(find.text('SMAPI is not installed'), findsOneWidget);
    });

    testWidgets('launcherSettingsOpensSeparatePage', (tester) async {
      await pumpLauncher(tester, path('launcher.ini'));
      await tester.tap(find.byKey(const ValueKey('settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gameDirectoryValue')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('configureChickPix')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chickPixDialog')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backLibrary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settingsPage')), findsNothing);
    });

    testWidgets('missingExecutableShowsWarning', (tester) async {
      final config = LauncherConfig(path('launcher.ini'));
      expect(config.saveGameDirectory(temp), isTrue);
      await pumpLauncher(tester, config.filePath());
      await tester.tap(find.byKey(const ValueKey('playInstance')));
      await tester.pumpAndSettle();
      expect(find.text('Unable to launch'), findsOneWidget);
      expect(find.textContaining('Executable not found'), findsWidgets);
    });

    testWidgets('chickPixSaveUpdatesLibrary', (tester) async {
      final config = LauncherConfig(path('launcher.ini'));
      await pumpLauncher(tester, config.filePath());
      await tester.tap(find.byKey(const ValueKey('settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('configureChickPix')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chickPixEnabled')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chickPixSave')));
      await tester.pumpAndSettle();
      expect(find.text('Saved ChickPix settings.'), findsOneWidget);
      expect(LauncherConfig(config.filePath()).farmPackEnabled(), isFalse);
      expect(LauncherConfig(config.filePath()).farmPackImage(), ChickPixImages.defaultImage());
    });
  });
}
