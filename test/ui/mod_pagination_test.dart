// Port of tests/ui/ModPaginationTests.cpp.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:prismatic_launcher/ui/nexus_page.dart';

import '../nexus/nexus_fetch_list_test.dart' show FixtureNetwork;

/// @brief Builds a GraphQL page response with [size] mods starting after [offset].
String response(int offset, int size, int total) => jsonEncode({
      'data': {
        'mods': {
          'nodes': [
            for (var index = 0; index < size; ++index)
              {'modId': offset + index + 1, 'name': 'Mod ${offset + index + 1}'},
          ],
          'totalCount': total,
        },
      },
    });

void main() {
  testWidgets('pagedBrowsingKeepsResultsOnFailure', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final network = FixtureNetwork()..responses.add((response(0, 50, 105), 200));
    final pageKey = GlobalKey<NexusPageState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NexusPage(key: pageKey, apiKey: 'fixture-key', networkManager: network.client),
      ),
    ));
    final browser = pageKey.currentState!.browser;

    // Port note: Qt fetched on an explicit fetchMods(); the Flutter page fetches on start, and
    // the mock response can complete within pumpWidget. The "Next disabled while loading"
    // check is covered after tapping Next below.
    await tester.pumpAndSettle();
    expect(browser.filtered, hasLength(50));
    expect(browser.filtered.first.name, 'Mod 1');
    expect(find.text('Mod 1'), findsOneWidget);
    expect(browser.previousEnabled, isFalse);
    expect(browser.nextEnabled, isTrue);
    expect(browser.pageCount, contains('105'));

    network.responses.add((response(50, 50, 105), 200));
    await tester.tap(find.byKey(const ValueKey('modNext')));
    expect(browser.nextEnabled, isFalse);
    expect(browser.previousEnabled, isFalse);
    pageKey.currentState!.fetchMods(); // A second request during loading must be ignored.
    await tester.pumpAndSettle();
    expect(network.requests, hasLength(2));
    expect(browser.filtered.first.name, 'Mod 51');
    expect(browser.previousEnabled, isTrue);
    expect(browser.nextEnabled, isTrue);

    network.responses
        .add(('{"mod_id":51,"name":"Mod 51","description":"Details","available":true}', 200));
    await tester.tap(find.text('Mod 51'));
    await tester.pumpAndSettle();
    expect(browser.description, 'Details');
    expect(browser.downloadEnabled, isTrue);

    network.responses.add(('{}', 429));
    await tester.tap(find.byKey(const ValueKey('modNext')));
    await tester.pumpAndSettle();
    expect(browser.nextEnabled, isTrue);
    expect(browser.filtered, hasLength(50));
    expect(browser.filtered.first.name, 'Mod 51');
    expect(browser.status, contains('429'));
    expect(browser.selectedId, 51);
    expect(browser.description, 'Details');
    expect(browser.downloadEnabled, isTrue);

    network.responses.add((response(100, 5, 105), 200));
    await tester.tap(find.byKey(const ValueKey('modNext')));
    await tester.pumpAndSettle();
    expect(browser.filtered, hasLength(5));
    expect(browser.filtered.first.name, 'Mod 101');
    expect(browser.selectedId, 0);
    expect(browser.downloadEnabled, isFalse);
    expect(browser.nextEnabled, isFalse);
    expect(browser.previousEnabled, isTrue);

    network.responses.add((response(50, 50, 105), 200));
    await tester.tap(find.byKey(const ValueKey('modPrevious')));
    await tester.pumpAndSettle();
    expect(browser.filtered.first.name, 'Mod 51');

    network.responses.add((response(0, 50, 105), 200));
    await tester.tap(find.byKey(const ValueKey('modRefresh')));
    await tester.pumpAndSettle();
    expect(browser.filtered.first.name, 'Mod 1');
    expect(browser.previousEnabled, isFalse);

    final offsets = [
      for (final request in network.requests)
        if (request.method == 'POST')
          ((jsonDecode(request.body) as Map<String, dynamic>)['variables']
              as Map<String, dynamic>)['offset'],
    ];
    expect(offsets, [0, 50, 100, 100, 50, 0]);

    await tester.enterText(find.byKey(const ValueKey('modSearch')), 'no matches on this page');
    await tester.pump();
    expect(browser.filtered, isEmpty);
    expect(browser.nextEnabled, isTrue);
    expect(browser.status, contains('on this page'));
    await tester.enterText(find.byKey(const ValueKey('modSearch')), '');
    await tester.pump();
    expect(browser.filtered, hasLength(50));

    network.responses.add(
        ('{"mod_id":1,"name":"Mod 1","description":"First page details","available":true}', 200));
    await tester.tap(find.text('Mod 1'));
    await tester.pumpAndSettle();
    expect(browser.description, 'First page details');

    network.responses.add((response(0, 50, 105), 200));
    await tester.tap(find.byKey(const ValueKey('modRefresh')));
    await tester.pumpAndSettle();
    expect(browser.refreshEnabled, isTrue);
    expect(browser.selectedId, 0);
    expect(browser.downloadEnabled, isFalse);
  });

  testWidgets('missingApiKeyExplainsSetup', (tester) async {
    final network = FixtureNetwork();
    final pageKey = GlobalKey<NexusPageState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NexusPage(key: pageKey, apiKey: '', networkManager: network.client)),
    ));
    await tester.pumpAndSettle();
    expect(pageKey.currentState!.browser.status, contains('NEXUS_API_KEY'));
    expect(network.requests, isEmpty);
  });
}
