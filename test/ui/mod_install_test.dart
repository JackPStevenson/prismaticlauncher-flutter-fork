// Port of the main scenarios in tests/ui/ModInstallTests.cpp.
//
// Port note: installs run on a real background isolate, so these widget tests wait with
// tester.runAsync, the Flutter equivalent of QTRY_VERIFY waiting on a QThread.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/ui/launcher_config.dart';
import 'package:prismatic_launcher/ui/mod_install_page.dart';

import '../mods/mod_installer_test.dart' show makeGame, makeMod;
import '../smapi/smapi_fixture.dart' show temporaryDirectory;

/// @brief Pumps until the page finishes its background operation.
Future<void> waitUntilIdle(WidgetTester tester, GlobalKey<ModInstallPageState> key) async {
  for (var attempt = 0; attempt < 200 && key.currentState!.isBusy; ++attempt) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(key.currentState!.isBusy, isFalse);
}

void main() {
  late String temp;
  setUp(() => temp = temporaryDirectory(addTearDown).path);

  testWidgets('installsFolderListsItAndReportsActivity', (tester) async {
    final game = makeGame(temp);
    final config = LauncherConfig(p.join(temp, 'launcher.ini'));
    expect(config.saveGameDirectory(game), isTrue);
    final activity = <String>[];
    final finished = <bool>[];
    final key = GlobalKey<ModInstallPageState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModInstallPage(
            key: key, config: config, onActivity: activity.add, onOperationFinished: finished.add),
      ),
    ));
    await waitUntilIdle(tester, key);
    expect(find.textContaining('No mods installed'), findsOneWidget);
    expect(find.textContaining(p.join(game, 'Mods')), findsOneWidget);

    makeMod(p.join(temp, 'download/MyMod'));
    final install = key.currentState!.installSources([p.join(temp, 'download/MyMod')]);
    await tester.pump();
    // The console hears about an install as soon as it starts, not only when it finishes.
    expect(activity.single, startsWith('Installing 1 selection(s)'));
    await waitUntilIdle(tester, key);
    await install;
    await tester.pump();

    expect(activity.last, startsWith('Installed 1 mod(s)'));
    expect(finished.last, isTrue);
    expect(find.text('Test.Mod'), findsOneWidget);
    expect(find.text('1 installed mod(s)'), findsOneWidget);
    expect(File(p.join(game, 'Mods/MyMod/Test.dll')).existsSync(), isTrue);
  });

  testWidgets('failedInstallShowsErrorWithoutPublishing', (tester) async {
    final game = makeGame(temp);
    final config = LauncherConfig(p.join(temp, 'launcher.ini'));
    expect(config.saveGameDirectory(game), isTrue);
    final activity = <String>[];
    final key = GlobalKey<ModInstallPageState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ModInstallPage(key: key, config: config, onActivity: activity.add)),
    ));
    await waitUntilIdle(tester, key);

    File(p.join(temp, 'loose.xnb')).writeAsStringSync('not a mod');
    final install = key.currentState!.installSources([p.join(temp, 'loose.xnb')]);
    await tester.pump();
    await waitUntilIdle(tester, key);
    await install;
    await tester.pump();
    expect(activity.last, startsWith('Installation failed: No manifest.json found'));
    expect(find.textContaining('Installation failed'), findsOneWidget);
    expect(Directory(p.join(game, 'Mods')).existsSync(), isFalse);
  });
}
