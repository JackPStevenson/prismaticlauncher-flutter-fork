// Port of tests/ui/LogWindowTests.cpp.
//
// Port notes:
// - Assertions run against LogWindowController, which holds the logic that the Qt
//   LogWindow kept inside its QTableWidget. `consoleText` rebuilds the same
//   "[LEVEL] [Source] message" lines the C++ helper read from table cells.
// - Header clicks call sortByColumn(); one widget test checks the header wiring itself.
// - Pixel-exact viewport tests (appendingPreservesScrollPosition and friends) have no
//   equivalent because the Flutter console only pins to the bottom; see log_window.dart.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/smapi/smapi_version.dart';
import 'package:prismatic_launcher/ui/instance_window.dart';
import 'package:prismatic_launcher/ui/launcher_config.dart';
import 'package:prismatic_launcher/ui/log_window.dart';

import '../smapi/smapi_fixture.dart';

/// @brief Reconstructs the visible level/source/message text for console assertions.
String consoleText(LogWindowController window) => window.visibleEntries
    .map((entry) =>
        '[${LogWindowController.severityName(entry.severity)}] [${entry.source}] ${entry.message}')
    .join('\n');

List<String> messages(LogWindowController window) =>
    window.visibleEntries.map((entry) => entry.message).toList();

/// @brief Installs a SMAPI fixture whose executable is the supplied shell script.
void writeFixture(String gameDirectory, String script) {
  const version = SmapiVersion(major: 4, minor: 5, patch: 2);
  createSmapiFixture(gameDirectory, version, version);
  final executable = p.join(gameDirectory, 'StardewModdingAPI');
  File(executable).writeAsStringSync(script);
  makeExecutable(executable);
}

/// @brief Waits for [condition] to become true, like QTRY_VERIFY.
Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for condition.');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('textHeaderSortCycleRestoresChronology', () {
    final window = LogWindowController()
      ..appendOutput('[12:00:03 INFO Beta] alpha\n'
          '[12:00:01 WARN Alpha] zulu\n'
          '[12:00:02 INFO Beta] middle\n');
    expect(messages(window), ['zulu', 'middle', 'alpha']);
    window.sortByColumn(3);
    expect(messages(window), ['alpha', 'middle', 'zulu']);
    window.sortByColumn(3);
    expect(messages(window), ['zulu', 'middle', 'alpha']);
    window.sortByColumn(3);
    expect(messages(window), ['zulu', 'middle', 'alpha']);
    window.sortByColumn(2);
    expect(window.visibleEntries.first.source, 'Alpha');
    window.sortByColumn(2);
    expect(messages(window), ['alpha', 'middle', 'zulu']);
    window.sortByColumn(2);
    expect(messages(window), ['zulu', 'middle', 'alpha']);
  });

  // Level headers sort severity in both directions before resetting chronological order.
  test('levelHeaderSortCycleUsesSeverityOrder', () {
    final window = LogWindowController()
      ..appendOutput('[12:00:03 ERROR Mod] error-first\n'
          '[12:00:01 WARN Mod] warning\n'
          '[12:00:02 DEBUG Mod] debug\n'
          '[12:00:04 ERROR Mod] error-second\n');
    window.sortByColumn(1);
    expect(messages(window), ['debug', 'warning', 'error-first', 'error-second']);
    window.sortByColumn(1);
    expect(messages(window), ['error-first', 'error-second', 'warning', 'debug']);
    window.sortByColumn(1);
    expect(messages(window), ['warning', 'debug', 'error-first', 'error-second']);
  });

  // Timestamp sorting compares numeric times and preserves arrival order for equal times.
  test('timestampHeaderSortsChronologicallyWithStableTies', () {
    final window = LogWindowController()
      ..appendOutput('[12:00:00.9 INFO Mod] late\n'
          '[12:00:00.10 INFO Mod] first-tie\n'
          '[12:00:00.100 INFO Mod] second-tie\n'
          '[09:00:00 INFO Mod] early\n');
    expect(messages(window).take(3), ['early', 'first-tie', 'second-tie']);
    window
      ..sortByColumn(0)
      ..sortByColumn(0);
    expect(messages(window), ['late', 'first-tie', 'second-tie', 'early']);
    window.sortByColumn(0);
    expect(messages(window).first, 'early');
  });

  // Untimestamped game and launcher rows receive a valid time captured at receipt.
  test('untimestampedRowsReceiveReceiptTime', () {
    final before = DateTime.now();
    final window = LogWindowController()
      ..appendOutput('plain game output\n[99:99:99 INFO Mod] invalid time\n')
      ..appendMessage('launcher message');
    final after = DateTime.now();
    expect(window.visibleEntries, hasLength(3));
    Duration timeOfDay(DateTime time) => Duration(
        hours: time.hour,
        minutes: time.minute,
        seconds: time.second,
        milliseconds: time.millisecond);
    for (final entry in window.visibleEntries) {
      if (before.day == after.day) {
        expect(entry.timestamp >= timeOfDay(before) && entry.timestamp <= timeOfDay(after), isTrue);
      }
    }
  });

  test('selectedRowsCopyAsPlainText', () {
    final window = LogWindowController()
      ..appendMessage('<b>first</b> & text', Severity.warn, 'Farm Mod')
      ..appendMessage('second-line', Severity.error, 'Other Mod');
    for (final entry in window.visibleEntries) {
      window.selectRow(entry.sequence, extend: true);
    }
    final copied = window.selectionText();
    expect(copied, contains('<b>first</b> & text'));
    expect(copied, contains('Farm Mod'));
    expect(copied, contains('WARN'));
    expect(copied, contains(formatTimestamp(window.visibleEntries.first.timestamp)));
    expect('second-line'.allMatches(copied), hasLength(1));
    window.setFilterText('first');
    expect(window.selectionText(), contains('<b>first</b> & text'));
    expect(window.selectionText(), isNot(contains('second-line')));
  });

  // Copying one selected row excludes unselected output and keeps literal text.
  test('copyingSelectedRowExcludesOtherRows', () {
    final window = LogWindowController()
      ..appendMessage('selected literal <tag>')
      ..appendMessage('unselected output');
    window.selectRow(window.visibleEntries.first.sequence);
    expect(window.selectionText(), contains('selected literal <tag>'));
    expect(window.selectionText(), isNot(contains('unselected output')));
  });

  test('filteringAndAppendingPreserveActiveSort', () {
    final window = LogWindowController()
      ..appendMessage('charlie')
      ..appendMessage('alpha')
      ..sortByColumn(3)
      ..setFilterText('a')
      ..appendMessage('bravo');
    expect(messages(window), ['alpha', 'bravo', 'charlie']);
  });

  test('minimumSeverityFiltersRetainedMessages', () {
    final window = LogWindowController()
      ..appendMessage('trace-line', Severity.trace)
      ..appendMessage('warn-line', Severity.warn)
      ..setMinimumSeverity(Severity.warn);
    expect(consoleText(window), isNot(contains('trace-line')));
    expect(consoleText(window), contains('warn-line'));
    window.setMinimumSeverity(Severity.trace);
    expect(consoleText(window), contains('trace-line'));
  });

  test('streamedRecordsPreserveSourceAndSeverity', () {
    final window = LogWindowController()..appendOutput('[12:34:56 TRA');
    expect(consoleText(window), isEmpty);
    window
      ..appendOutput('CE Mód Name] first-message\r')
      ..appendOutput('\n    stack-detail\r\n[12:34:57 ERROR Other Mod] failure-message\n');
    final lines = consoleText(window).split('\n').where((line) => line.isNotEmpty).toList();
    expect(lines, hasLength(3));
    expect(consoleText(window), contains('[Mód Name] first-message'));
    expect(consoleText(window), contains('[Mód Name]     stack-detail'));
    expect(consoleText(window), isNot(contains('\r')));
    window.setMinimumSeverity(Severity.error);
    expect(consoleText(window), isNot(contains('first-message')));
    expect(consoleText(window), isNot(contains('stack-detail')));
    expect(consoleText(window), contains('failure-message'));
  });

  // Console and BepInEx prefixes retain source names and explicit severity.
  test('consoleFormatsIdentifySources', () {
    final window = LogWindowController()
      ..appendOutput('initial-game-output\n[Farm Mod] console-info\n[Warning: Weather Mod] '
          'weather-warning\n');
    final lines = consoleText(window).split('\n');
    expect(lines, hasLength(3));
    expect(lines[0], contains('[Game]'));
    expect(lines[1], contains('[Farm Mod]'));
    expect(lines[2], contains('[Weather Mod]'));
    window.setMinimumSeverity(Severity.warn);
    expect(consoleText(window), isNot(contains('initial-game-output')));
    expect(consoleText(window), isNot(contains('console-info')));
    expect(consoleText(window), contains('weather-warning'));
  });

  // Flushing emits an unfinished plain-text message once, including literal markup.
  test('flushingTailDisplaysLiteralTextOnce', () {
    final window = LogWindowController()..appendOutput('[Markup Mod] <b>literal</b> & text');
    expect(consoleText(window), isEmpty);
    window.flushOutput();
    expect(consoleText(window), contains('[Markup Mod]'));
    expect(consoleText(window), contains('<b>literal</b> & text'));
    final flushed = consoleText(window);
    window.flushOutput();
    expect(consoleText(window), flushed);
  });

  // Search and severity combine reversibly across retained records.
  test('searchAndSeverityFiltersAreReversible', () {
    final window = LogWindowController()
      ..appendMessage('first-info', Severity.info, 'Farm Mod')
      ..appendMessage('second-error', Severity.error, 'Farm Mod')
      ..appendMessage('other-error', Severity.error, 'Weather Mod')
      ..setFilterText('farm')
      ..setMinimumSeverity(Severity.error);
    expect(consoleText(window), contains('second-error'));
    expect(consoleText(window), isNot(contains('first-info')));
    expect(consoleText(window), isNot(contains('other-error')));
    window
      ..setFilterText('')
      ..setMinimumSeverity(Severity.trace);
    expect(consoleText(window), contains('first-info'));
    expect(consoleText(window), contains('other-error'));
  });

  // Clearing discards pending fragments and resets inherited metadata.
  test('clearResetsHistoryAndStreamContext', () {
    final window = LogWindowController()
      ..appendOutput('[12:34:56 ERROR Old Mod] old-message\npending-old-tail')
      ..clearHistory();
    expect(consoleText(window), isEmpty);
    window
      ..appendOutput('new-game-message\n')
      ..flushOutput();
    expect(consoleText(window), contains('[Game]'));
    expect(consoleText(window), isNot(contains('Old Mod')));
    expect(consoleText(window), isNot(contains('pending-old-tail')));
  });

  // History evicts old records even while the severity filter hides them.
  test('historyEvictsOldestRecords', () {
    final window = LogWindowController()
      ..sortByColumn(3)
      ..sortByColumn(3)
      ..setMinimumSeverity(Severity.fatal);
    for (var index = 0; index < 5002; ++index) {
      window.appendMessage('record-$index-end');
    }
    window.setMinimumSeverity(Severity.trace);
    final text = consoleText(window);
    expect(text, isNot(contains('record-0-end')));
    expect(text, isNot(contains('record-1-end')));
    expect(text, contains('record-2-end'));
    expect(text, contains('record-5001-end'));
    expect(text.split('\n'), hasLength(5000));
  });

  // Native SMAPI aliases and split-screen stamps preserve the actual mod name.
  test('nativeSmapiStamps', () {
    final window = LogWindowController()
      ..appendOutput('[12:00:00 SUCCESS screen_1 Farm Mod] success-marker\n'
          '[12:00:01 CRITICAL screen_2 Farm Mod] fatal-marker\n');
    expect(consoleText(window), contains('[INFO] [Farm Mod] success-marker'));
    expect(consoleText(window), contains('[FATAL] [Farm Mod] fatal-marker'));
    window.setMinimumSeverity(Severity.fatal);
    expect(consoleText(window), isNot(contains('success-marker')));
    expect(consoleText(window), contains('fatal-marker'));
  });

  // A new process resets attribution and CRLF state while retaining history.
  test('newSessionResetsAttribution', () {
    final window = LogWindowController()
      ..appendOutput('[12:00:00 ERROR Old Mod] retained\r')
      ..beginSession()
      ..appendOutput('fresh-message\n');
    expect(consoleText(window), contains('[ERROR] [Old Mod] retained'));
    expect(consoleText(window), contains('[INFO] [Game] fresh-message'));
    window
      ..appendOutput('[Old Mod] pending-tail')
      ..beginSession();
    expect(consoleText(window), contains('[Old Mod] pending-tail'));
  });

  // Long streamed lines keep complete Unicode characters at the split boundary.
  test('longLinesPreserveUnicode', () {
    const prefix = '[12:00:00 WARN Farm Mod] ';
    final padding = 'x' * (16383 - prefix.length);
    const emoji = '🌱';
    final window = LogWindowController()..appendOutput('$prefix$padding${emoji}tail\n');
    final lines = consoleText(window).split('\n');
    expect(lines, hasLength(2));
    expect(lines[0], startsWith('[WARN] [Farm Mod] '));
    expect(lines[1], startsWith('[WARN] [Farm Mod] '));
    expect(consoleText(window), contains(emoji));
    expect(lines[0].endsWith('tail') || lines[1].endsWith('tail'), isTrue);
    window
      ..beginSession()
      ..appendOutput('fresh-after-fragment\n');
    expect(consoleText(window), contains('[INFO] [Game] fresh-after-fragment'));
  });

  testWidgets('consoleHasTimestampedColumns and header taps sort', (tester) async {
    final window = LogWindowController()
      ..appendOutput('[12:00:02 INFO Beta] bravo\n[12:00:01 INFO Alpha] alpha-last\n');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LogWindow(controller: window))));
    for (final header in ['Timestamp', 'Level', 'Source', 'Message']) {
      expect(find.textContaining(header), findsOneWidget);
    }
    expect(find.text('12:00:01.000'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('logHeader3')));
    await tester.pump();
    expect(messages(window), ['alpha-last', 'bravo']);
    window.dispose();
  });

  testWidgets('copyShortcutWritesClipboard', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
      }
      return null;
    });
    final window = LogWindowController()..appendMessage('copy-me');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LogWindow(controller: window))));
    await tester.tap(find.text('copy-me'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied.single, contains('copy-me'));
    window.dispose();
  });

  group('process capture', () {
    late String temp;
    setUp(() => temp = temporaryDirectory(addTearDown).path);

    test('playCapturesProcessOutput', () async {
      writeFixture(
          temp,
          '#!/bin/sh\n'
          'test "\$1" = --developer-mode || exit 8\n'
          'test "\$SMAPI_USE_CURRENT_SHELL" = true || exit 9\n'
          "printf '[12:00:00 ERROR Fixture M'\n"
          'sleep 0.03\n'
          r"printf 'od] caf\303'"
          '\n'
          'sleep 0.03\n'
          r"printf '\251\n'"
          '\n'
          r"printf '[12:00:01 WARN Fixture Mod] stderr-marker\n' >&2"
          '\n'
          "printf '[12:00:02 INFO Fixture Mod] final-tail'\n");
      final config = LauncherConfig(p.join(temp, 'launcher.ini'));
      expect(config.saveGameDirectory(temp), isTrue);
      final instance = InstanceWindowController('Fixture', true, config);
      final logs = instance.logWindow;

      expect(await instance.launchGame(), isNull);
      await waitFor(() => consoleText(logs).contains('Game exited with code 0.'));
      expect(consoleText(logs), contains('[ERROR] [Fixture Mod] café'));
      expect(consoleText(logs), contains('[WARN] [Fixture Mod] stderr-marker'));
      expect(consoleText(logs), contains('[INFO] [Fixture Mod] final-tail'));
      expect(instance.selectedTab, InstanceTab.console);

      // A second launch uses the same capture path after the first process exits.
      await instance.launchGame();
      await waitFor(() => 'Game exited with code 0.'.allMatches(consoleText(logs)).length == 2);
      instance.dispose();
    }, skip: Platform.isWindows);

    // Disposing the instance state leaves the captured process alive until it exits.
    test('destroyingWindowDoesNotKillGame', () async {
      writeFixture(temp, '#!/bin/sh\nsleep 0.2\ntouch survived.marker\n');
      final config = LauncherConfig(p.join(temp, 'launcher.ini'));
      expect(config.saveGameDirectory(temp), isTrue);
      final instance = InstanceWindowController('Fixture', true, config);
      await instance.launchGame();
      instance.dispose();
      await waitFor(() => File(p.join(temp, 'survived.marker')).existsSync());
    }, skip: Platform.isWindows);

    test('moddedLaunchRequiresSmapi', () async {
      final config = LauncherConfig(p.join(temp, 'launcher.ini'));
      expect(config.saveGameDirectory(temp), isTrue);
      final instance = InstanceWindowController('Fixture', true, config);
      final warning = await instance.launchGame();
      expect(warning?.title, 'Unable to launch SMAPI');
      expect(consoleText(instance.logWindow), contains('SMAPI is not installed'));
      instance.dispose();
    });

    test('missingExecutable', () async {
      final config = LauncherConfig(p.join(temp, 'launcher.ini'));
      expect(config.saveGameDirectory(temp), isTrue);
      final instance = InstanceWindowController('Fixture', false, config);
      final warning = await instance.launchGame();
      expect(warning?.title, 'Unable to launch');
      expect(consoleText(instance.logWindow), contains('Executable not found'));
      instance.dispose();
    });
  });
}
