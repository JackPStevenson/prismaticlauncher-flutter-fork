// Port of tests/nexus_fetch_list_test.cpp and tests/nexus_mod_pages_test.cpp.
//
// Port note: the C++ FixtureNetwork (a fake QNetworkAccessManager) became http's MockClient,
// and QSignalSpy became plain lists filled by stream listeners.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:prismatic_launcher/common/error_message.dart';
import 'package:prismatic_launcher/nexus_fetch_list/nexus_fetch_list.dart';

List<int> bytes(String text) => utf8.encode(text);

NexusModSummary summary(int id, String name, String summaryText, String author) => NexusModSummary()
  ..id = id
  ..name = name
  ..summary = summaryText
  ..author = author;

/// @brief Returns queued responses in order and records every request (FixtureNetwork).
class FixtureNetwork {
  final List<(String, int)> responses = [];
  final List<http.Request> requests = [];

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final (body, status) = responses.removeAt(0);
    return http.Response(body, status);
  });
}

void main() {
  group('NexusFetchListTest', () {
    test('filtersModListByNameSummaryAndAuthor', () {
      final mods = [
        summary(1, 'Stardew Valley Expanded', 'An expansion', 'FlashShifter'),
        summary(2, 'Lookup Anything', 'Inspect the world', 'Pathoschild'),
      ];
      expect(NexusModClient.searchMods(mods, 'FLASH'), [mods.first]);
      expect(NexusModClient.searchMods(mods, 'world'), [mods.last]);
      expect(NexusModClient.searchMods(mods, 'missing'), isEmpty);
    });

    test('parsesAValidLatestUpdatedResponse', () {
      final error = ErrorMessage();
      final mods = NexusModClient.parseModListResponse(bytes('''[{
          "mod_id": 456, "name": "List Entry", "summary": "From the latest-updated endpoint",
          "version": "1.0.0", "author": "ExampleAuthor", "endorsement_count": 3
      }]'''), error);
      expect(mods, isNotNull, reason: error.value);
      expect(mods!.single.id, 456);
      expect(mods.single.pageUrl!.path, '/stardewvalley/mods/456');
    });

    test('parsesAnUnavailableModWithoutAName', () {
      final error = ErrorMessage();
      final mods = NexusModClient.parseModListResponse(bytes('''[{
          "mod_id": 789, "name": null, "summary": null, "version": null, "author": null,
          "endorsement_count": 0
      }]'''), error);
      expect(mods, isNotNull, reason: error.value);
      expect(mods!.single.name, 'Unavailable mod #789');
    });

    test('parsesAValidModDetailsResponse', () {
      final error = ErrorMessage();
      final mod = NexusModClient.parseModDetailsResponse(bytes('''{
          "mod_id": 123, "name": "Example Mod", "summary": "A test mod",
          "description": "<p>Long description</p>", "version": "2.4.0",
          "author": "ExampleAuthor", "uploaded_by": "Uploader",
          "created_time": 1700000000, "updated_time": 1700000100,
          "mod_downloads": 42, "mod_unique_downloads": 12, "endorsement_count": 7,
          "adult_content": false, "available": true, "category_name": "Gameplay"
      }'''), error);
      expect(mod, isNotNull, reason: error.value);
      expect(mod!.id, 123);
      expect(mod.description, '<p>Long description</p>');
      expect(mod.version, '2.4.0');
      expect(mod.updatedAt, DateTime.fromMillisecondsSinceEpoch(1700000100000, isUtc: true));
      expect(mod.downloadCount, 42);
      expect(mod.available, isTrue);
    });

    test('parsesModDetailsWithNumericStringTimestamps', () {
      final mod = NexusModClient.parseModDetailsResponse(bytes(
          '{"mod_id":124,"name":"Timestamp Mod","created_time":"1700000000","updated_time":"1700000100"}'));
      expect(mod!.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
      expect(mod.updatedAt, DateTime.fromMillisecondsSinceEpoch(1700000100000, isUtc: true));
    });

    test('parsesModDetailsWithIsoTimestamps', () {
      final mod = NexusModClient.parseModDetailsResponse(bytes(
          '{"mod_id":125,"name":"ISO Timestamp Mod","created_time":"2023-11-14T22:13:20Z","updated_time":""}'));
      expect(mod!.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
      expect(mod.updatedAt, isNull);
    });

    test('rejectsMalformedModDetailsResponse', () {
      final error = ErrorMessage();
      expect(NexusModClient.parseModDetailsResponse(bytes('{"name":"missing id"}'), error), isNull);
      expect(error.value, isNotEmpty);
    });
  });

  group('NexusModPagesTest', () {
    test('requestsPagedResults', () async {
      final network = FixtureNetwork()
        ..responses.add(
            ('{"data":{"mods":{"totalCount":100,"nodes":[{"modId":42,"name":"Test"}]}}}', 200));
      final client = NexusModClient('fixture-key', networkManager: network.client);
      final fetched = <NexusModPage>[];
      client.modPageFetched.listen(fetched.add);

      await client.fetchModPage(50);
      final request = network.requests.single;
      expect(request.url, Uri.parse('https://api.nexusmods.com/v2/graphql'));
      expect(request.method, 'POST');
      expect(request.headers['apikey'], 'fixture-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final variables = body['variables'] as Map<String, dynamic>;
      expect(variables['offset'], 50);
      expect(variables['count'], 50);
      expect(body['query'], contains('stardewvalley'));
      expect(body['query'], contains('updatedAt'));
      expect(fetched.single.offset, 50);
      client.dispose();
    });

    test('pageNetworkErrorsAndInvalidOffsets', () async {
      final network = FixtureNetwork();
      final client = NexusModClient('fixture-key', networkManager: network.client);
      final failed = <NexusApiError>[];
      final fetched = <NexusModPage>[];
      client.requestFailed.listen(failed.add);
      client.modPageFetched.listen(fetched.add);

      await client.fetchModPage(-1);
      expect(failed, hasLength(1));
      expect(network.requests, isEmpty);

      final missingKey = NexusModClient('', networkManager: network.client);
      final missingKeyErrors = <NexusApiError>[];
      missingKey.requestFailed.listen(missingKeyErrors.add);
      await missingKey.fetchModPage();
      expect(missingKeyErrors, hasLength(1));
      expect(network.requests, isEmpty);

      network.responses.add(('{}', 429));
      await client.fetchModPage();
      expect(failed, hasLength(2));
      expect(failed.last.httpStatus, 429);

      network.responses.add(('{"errors":[{"message":"sensitive remote error"}]}', 200));
      await client.fetchModPage();
      expect(failed, hasLength(3));
      expect(failed.last.message, isNot(contains('sensitive')));
      expect(fetched, isEmpty);
      client.dispose();
      missingKey.dispose();
    });

    test('parsesPagedResponse', () {
      final error = ErrorMessage();
      final page = NexusModClient.parseModPageResponse(
          bytes(
              '{"data":{"mods":{"totalCount":120,"nodes":[{"modId":456,"name":"Page two","author":null,"endorsements":4}]}}}'),
          50,
          error);
      expect(page, isNotNull, reason: error.value);
      expect(page!.offset, 50);
      expect(page.totalCount, 120);
      expect(page.mods.single.id, 456);
      expect(page.mods.single.endorsementCount, 4);
      expect(page.mods.single.pageUrl!.path, '/stardewvalley/mods/456');
    });

    for (final (row, response) in [
      ('invalid json', '{'),
      (
        'graphql failure',
        '{"errors":[{"message":"Denied"}],"data":{"mods":{"nodes":[],"totalCount":0}}}'
      ),
      ('missing count', '{"data":{"mods":{"nodes":[]}}}'),
      ('wrong count type', '{"data":{"mods":{"nodes":[],"totalCount":"50"}}}'),
      ('negative count', '{"data":{"mods":{"nodes":[],"totalCount":-1}}}'),
      ('missing nodes', '{"data":{"mods":{"totalCount":50}}}'),
      ('invalid id', '{"data":{"mods":{"totalCount":1,"nodes":[{"modId":0}]}}}'),
      ('invalid name', '{"data":{"mods":{"totalCount":1,"nodes":[{"modId":1,"name":true}]}}}'),
    ]) {
      test('rejectsInvalidPages ($row)', () {
        final error = ErrorMessage();
        expect(NexusModClient.parseModPageResponse(bytes(response), 0, error), isNull);
        expect(error.value, isNotEmpty);
      });
    }

    test('parsesEmptyPage', () {
      final page = NexusModClient.parseModPageResponse(
          bytes('{"data":{"mods":{"totalCount":0,"nodes":[]}}}'));
      expect(page, isNotNull);
      expect(page!.mods, isEmpty);
      expect(page.totalCount, 0);
    });
  });
}
