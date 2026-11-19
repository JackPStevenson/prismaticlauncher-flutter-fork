// Port of src/Nexus_fetchList/Nexus_fetchList.{hpp,cpp} and NexusModPages.cpp.
//
// Read-only Nexus Mods client for the Stardew Valley game domain.
//
// Port notes:
// - Qt signals (modPageFetched, modListFetched, modDetailsFetched, requestFailed) became
//   broadcast Streams with the same names, so callers still "connect" by listening.
// - QNetworkAccessManager became an injectable `http.Client` (tests pass a MockClient).
// - The fetch methods return a Future that completes after the matching stream event has
//   been emitted, which replaces returning a QNetworkReply*.
// - This file has no Flutter imports so the command-line tool in bin/ can use it.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../common/error_message.dart';

class NexusModSummary {
  int id = 0;
  String name = '';
  String summary = '';
  String version = '';
  String author = '';
  Uri? pageUrl;
  Uri? pictureUrl;
  int endorsementCount = 0;

  // Replaces the C++ defaulted operator==.
  @override
  bool operator ==(Object other) =>
      other is NexusModSummary &&
      other.id == id &&
      other.name == name &&
      other.summary == summary &&
      other.version == version &&
      other.author == author &&
      other.pageUrl == pageUrl &&
      other.pictureUrl == pictureUrl &&
      other.endorsementCount == endorsementCount;

  @override
  int get hashCode => Object.hash(id, name, summary, version, author, endorsementCount);
}

class NexusModDetails extends NexusModSummary {
  String description = '';
  String uploadedBy = '';
  String category = '';
  DateTime? createdAt;
  DateTime? updatedAt;
  int downloadCount = 0;
  int uniqueDownloadCount = 0;
  bool adultContent = false;
  bool available = false;
}

class NexusModPage {
  NexusModPage(this.mods, this.totalCount, this.offset);

  final List<NexusModSummary> mods;
  final int totalCount;
  final int offset;
}

class NexusApiError {
  const NexusApiError(this.message, this.httpStatus);

  final String message;
  final int httpStatus;
}

const String _kApiBaseUrl = 'https://api.nexusmods.com/v1/games/stardewvalley/mods/';
const int _kMaxInt32 = 2147483647;

// Contract: https://graphql.nexusmods.com/#query-mods (offset/count, newest updates first).
const String _pageQuery = r'''
query ModPage($offset: Int!, $count: Int!) {
  mods(filter: {gameDomainName: [{value: "stardewvalley", op: EQUALS}]},
       sort: [{updatedAt: {direction: DESC}}], offset: $offset, count: $count) {
    nodes { modId name summary version author pictureUrl endorsements }
    totalCount
  }
}''';

/// @brief Thrown internally when a response field has the wrong type; mirrors
/// `Json::exception` in the C++ parser.
class _FieldError implements Exception {}

// ------ JSON field readers (ported from the anonymous namespace) ------

/// @brief Reads the required positive integer `mod_id`.
int? _readRequiredId(Map<String, dynamic> object, ErrorMessage? error) {
  final id = object['mod_id'];
  if (id is! int) {
    setError(error, 'Nexus response is missing an integer mod_id.');
    return null;
  }
  return id;
}

/// @brief Reads an optional string; absent and null fields become an empty string.
/// @return False after recording an error when the field is present but not a string.
bool _readOptionalString(
    Map<String, dynamic> object, String key, void Function(String) assign, ErrorMessage? error) {
  final field = object[key];
  if (field == null) {
    assign('');
    return true;
  }
  if (field is! String) {
    setError(error, 'Nexus response has a non-string $key.');
    return false;
  }
  assign(field);
  return true;
}

/// @brief Reads an optional integer, also accepting numeric strings; absent means zero.
bool _readOptionalInteger(
    Map<String, dynamic> object, String key, void Function(int) assign, ErrorMessage? error) {
  final field = object[key];
  if (field == null) {
    assign(0);
    return true;
  }
  if (field is String) {
    final parsed = int.tryParse(field);
    if (parsed != null) {
      assign(parsed);
      return true;
    }
  }
  if (field is! int) {
    setError(error, 'Nexus response has a non-integer $key.');
    return false;
  }
  assign(field);
  return true;
}

/// @brief Reads a timestamp given as epoch seconds (number or string) or an ISO-8601 string.
bool _readOptionalTimestamp(
    Map<String, dynamic> object, String key, void Function(int) assign, ErrorMessage? error) {
  final field = object[key];
  if (field == null) {
    assign(0);
    return true;
  }
  if (field is! String) return _readOptionalInteger(object, key, assign, error);
  if (field.isEmpty) {
    assign(0);
    return true;
  }

  final numericValue = int.tryParse(field);
  if (numericValue != null) {
    assign(numericValue);
    return true;
  }

  final dateTime = DateTime.tryParse(field);
  if (dateTime != null) {
    assign(dateTime.millisecondsSinceEpoch ~/ 1000);
    return true;
  }

  setError(error, 'Nexus response has an invalid timestamp $key.');
  return false;
}

/// @brief Reads an optional boolean; absent means false.
bool _readOptionalBoolean(
    Map<String, dynamic> object, String key, void Function(bool) assign, ErrorMessage? error) {
  final field = object[key];
  if (field == null) {
    assign(false);
    return true;
  }
  if (field is! bool) {
    setError(error, 'Nexus response has a non-boolean $key.');
    return false;
  }
  assign(field);
  return true;
}

/// @brief Fills [summary] from a REST mod object and derives its page URL from the ID.
bool _parseSummary(Object? value, NexusModSummary summary, ErrorMessage? error) {
  if (value is! Map<String, dynamic>) {
    setError(error, 'Nexus response is missing an integer mod_id.');
    return false;
  }
  final object = value;
  final id = _readRequiredId(object, error);
  if (id == null) return false;
  summary.id = id;
  if (!_readOptionalString(object, 'name', (v) => summary.name = v, error) ||
      !_readOptionalString(object, 'summary', (v) => summary.summary = v, error) ||
      !_readOptionalString(object, 'version', (v) => summary.version = v, error) ||
      !_readOptionalString(object, 'author', (v) => summary.author = v, error) ||
      !_readOptionalInteger(
          object, 'endorsement_count', (v) => summary.endorsementCount = v, error)) {
    return false;
  }

  if (summary.name.isEmpty) summary.name = 'Unavailable mod #${summary.id}';

  var pictureUrl = '';
  if (!_readOptionalString(object, 'picture_url', (v) => pictureUrl = v, error)) return false;

  summary.pageUrl = Uri.parse('https://www.nexusmods.com/stardewvalley/mods/${summary.id}');
  summary.pictureUrl = pictureUrl.isEmpty ? null : Uri.tryParse(pictureUrl);
  return true;
}

/// @brief Decodes JSON, returning null instead of throwing for malformed input.
Object? _decodeOrNull(List<int> response) {
  try {
    return jsonDecode(utf8.decode(response, allowMalformed: true));
  } on FormatException {
    return null;
  }
}

/// @brief Read-only Nexus Mods client. The caller owns API-key storage and must never log
/// the supplied key.
class NexusModClient {
  /// @brief Creates a client; an injected [networkManager] is borrowed and not closed.
  NexusModClient(this._apiKey, {http.Client? networkManager})
      : _networkManager = networkManager ?? http.Client(),
        _ownsNetworkManager = networkManager == null;

  // Paged catalogue browsing uses GraphQL v2; the REST feed remains for the CLI.
  static const int pageSize = 50;

  final String _apiKey;
  final http.Client _networkManager;
  final bool _ownsNetworkManager;
  bool _disposed = false;

  final _modPageFetched = StreamController<NexusModPage>.broadcast(sync: true);
  final _modListFetched = StreamController<List<NexusModSummary>>.broadcast(sync: true);
  final _modDetailsFetched = StreamController<NexusModDetails>.broadcast(sync: true);
  final _requestFailed = StreamController<NexusApiError>.broadcast(sync: true);

  // ------ signals ------
  Stream<NexusModPage> get modPageFetched => _modPageFetched.stream;
  Stream<List<NexusModSummary>> get modListFetched => _modListFetched.stream;
  Stream<NexusModDetails> get modDetailsFetched => _modDetailsFetched.stream;
  Stream<NexusApiError> get requestFailed => _requestFailed.stream;

  /// @brief Stops emitting events and releases the owned HTTP client.
  ///
  /// Replaces deleting the QObject: late responses for a disposed client are ignored, which
  /// is how the UI cancels a superseded details request.
  void dispose() {
    _disposed = true;
    _modPageFetched.close();
    _modListFetched.close();
    _modDetailsFetched.close();
    _requestFailed.close();
    if (_ownsNetworkManager) _networkManager.close();
  }

  void _emitFailure(NexusApiError error) {
    if (!_disposed) _requestFailed.add(error);
  }

  /// @brief Fetches the legacy API's ten most recently updated Stardew Valley mods.
  ///
  /// The period-based updated.json endpoint returns only IDs and timestamps; this endpoint
  /// returns the complete summaries required by NexusModSummary.
  Future<void> fetchModList() async {
    final reply = await _request(Uri.parse('${_kApiBaseUrl}latest_updated.json'));
    if (reply == null || _disposed) return;
    if (reply.statusCode < 200 || reply.statusCode >= 300) {
      _emitFailure(NexusApiError(reply.reasonPhrase ?? 'Request failed.', reply.statusCode));
      return;
    }
    final error = ErrorMessage();
    final mods = parseModListResponse(reply.bodyBytes, error);
    if (mods != null) {
      _modListFetched.add(mods);
    } else {
      _emitFailure(NexusApiError(error.value, reply.statusCode));
    }
  }

  /// @brief Fetches one page of mods through the GraphQL v2 API, starting at [offset].
  Future<void> fetchModPage([int offset = 0]) async {
    if (offset < 0 || offset > _kMaxInt32 - pageSize) {
      _emitFailure(const NexusApiError('Invalid mod page offset.', 0));
      return;
    }
    final body = jsonEncode({
      'query': _pageQuery,
      'variables': {'offset': offset, 'count': pageSize},
    });
    final reply = await _request(Uri.parse('https://api.nexusmods.com/v2/graphql'), body);
    if (reply == null || _disposed) return;
    final status = reply.statusCode;
    if (status < 200 || status >= 300) {
      _emitFailure(NexusApiError('Unable to load the Nexus mod page.', status));
      return;
    }
    final error = ErrorMessage();
    final page = parseModPageResponse(reply.bodyBytes, offset, error);
    if (page != null) {
      _modPageFetched.add(page);
    } else {
      _emitFailure(NexusApiError(error.value, status));
    }
  }

  /// @brief Fetches the full details for one mod.
  Future<void> fetchModDetails(int modId) async {
    if (modId <= 0) {
      _emitFailure(const NexusApiError('A Nexus mod ID must be positive.', 0));
      return;
    }

    final reply = await _request(Uri.parse('$_kApiBaseUrl$modId.json'));
    if (reply == null || _disposed) return;
    if (reply.statusCode < 200 || reply.statusCode >= 300) {
      _emitFailure(NexusApiError(reply.reasonPhrase ?? 'Request failed.', reply.statusCode));
      return;
    }
    final error = ErrorMessage();
    final mod = parseModDetailsResponse(reply.bodyBytes, error);
    if (mod != null) {
      _modDetailsFetched.add(mod);
    } else {
      _emitFailure(NexusApiError(error.value, reply.statusCode));
    }
  }

  /// @brief Filters an already-fetched list by name, summary, or author.
  static List<NexusModSummary> searchMods(List<NexusModSummary> mods, String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return List.of(mods);

    return mods
        .where((mod) =>
            mod.name.toLowerCase().contains(needle) ||
            mod.summary.toLowerCase().contains(needle) ||
            mod.author.toLowerCase().contains(needle))
        .toList();
  }

  // Parsing is public so callers can test and cache API responses without network I/O.

  /// @brief Parses a REST mod-list response (a bare array, or an object with `mods`).
  static List<NexusModSummary>? parseModListResponse(List<int> response, [ErrorMessage? error]) {
    final document = _decodeOrNull(response);
    if (document == null) {
      setError(error, 'Nexus returned invalid JSON.');
      return null;
    }

    Object? mods = document;
    if (document is Map<String, dynamic>) {
      if (!document.containsKey('mods')) {
        setError(error, 'Nexus mod-list response is missing mods.');
        return null;
      }
      mods = document['mods'];
    }
    if (mods is! List) {
      setError(error, 'Nexus mod-list response is not an array.');
      return null;
    }

    final parsed = <NexusModSummary>[];
    for (final entry in mods) {
      final mod = NexusModSummary();
      if (!_parseSummary(entry, mod, error)) return null;
      parsed.add(mod);
    }
    return parsed;
  }

  /// @brief Parses a REST mod-details response.
  static NexusModDetails? parseModDetailsResponse(List<int> response, [ErrorMessage? error]) {
    final document = _decodeOrNull(response);
    if (document is! Map<String, dynamic>) {
      setError(error, 'Nexus returned invalid mod-details JSON.');
      return null;
    }

    final details = NexusModDetails();
    if (!_parseSummary(document, details, error) ||
        !_readOptionalString(document, 'description', (v) => details.description = v, error) ||
        !_readOptionalString(document, 'uploaded_by', (v) => details.uploadedBy = v, error) ||
        !_readOptionalString(document, 'category_name', (v) => details.category = v, error)) {
      return null;
    }

    var createdTimestamp = 0;
    var updatedTimestamp = 0;
    if (!_readOptionalTimestamp(document, 'created_time', (v) => createdTimestamp = v, error) ||
        !_readOptionalTimestamp(document, 'updated_time', (v) => updatedTimestamp = v, error) ||
        !_readOptionalInteger(document, 'mod_downloads', (v) => details.downloadCount = v, error) ||
        !_readOptionalInteger(
            document, 'mod_unique_downloads', (v) => details.uniqueDownloadCount = v, error) ||
        !_readOptionalBoolean(document, 'adult_content', (v) => details.adultContent = v, error) ||
        !_readOptionalBoolean(document, 'available', (v) => details.available = v, error)) {
      return null;
    }

    if (createdTimestamp > 0) {
      details.createdAt = DateTime.fromMillisecondsSinceEpoch(createdTimestamp * 1000, isUtc: true);
    }
    if (updatedTimestamp > 0) {
      details.updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedTimestamp * 1000, isUtc: true);
    }
    return details;
  }

  /// @brief Parses a GraphQL v2 page response into summaries plus pagination metadata.
  static NexusModPage? parseModPageResponse(List<int> response,
      [int offset = 0, ErrorMessage? error]) {
    NexusModPage? fail(String message) {
      setError(error, message);
      return null;
    }

    try {
      final document = _decodeOrNull(response);
      if (document is! Map<String, dynamic> || offset < 0) {
        return fail('Invalid Nexus mod page response.');
      }
      final errors = document['errors'];
      if (document.containsKey('errors') && !(errors is List && errors.isEmpty)) {
        // Do not expose remote messages, request headers or partial results.
        return fail('Nexus could not complete the mod list query. Please retry.');
      }
      final data = document['data'];
      final page = data is Map<String, dynamic> ? data['mods'] : null;
      if (page is! Map<String, dynamic>) throw _FieldError();
      final total = page['totalCount'];
      final nodes = page['nodes'];
      if (total is! int ||
          total < 0 ||
          total > _kMaxInt32 ||
          nodes is! List ||
          nodes.length > pageSize ||
          nodes.length > total) {
        return fail('Invalid Nexus mod page metadata.');
      }

      // Rename GraphQL fields to the REST names so one summary parser serves both APIs.
      final summaries = <Object?>[];
      for (final node in nodes) {
        if (node is! Map<String, dynamic> || node['modId'] is! int || (node['modId'] as int) <= 0) {
          return fail('Invalid mod ID in Nexus page.');
        }
        summaries.add({
          ...node,
          'mod_id': node['modId'],
          'picture_url': node['pictureUrl'],
          'endorsement_count': node['endorsements'],
        });
      }
      final mods = parseModListResponse(utf8.encode(jsonEncode(summaries)), error);
      if (mods == null) return null;
      return NexusModPage(mods, total, offset);
    } on _FieldError {
      return fail('Invalid Nexus mod page fields.');
    }
  }

  /// @brief Sends an authenticated GET (or JSON POST when [body] is given).
  /// @return The response, or null after emitting requestFailed for a missing key, a
  /// network error, or a timeout.
  Future<http.Response?> _request(Uri url, [String body = '']) async {
    if (_apiKey.trim().isEmpty) {
      _emitFailure(const NexusApiError('A Nexus API key is required.', 0));
      return null;
    }

    final request = http.Request(body.isEmpty ? 'GET' : 'POST', url)
      ..headers['apikey'] = _apiKey
      ..headers['User-Agent'] = 'PrismaticLauncher/0.0.0'
      // Matches QNetworkRequest::ManualRedirectPolicy: never follow redirects silently.
      ..followRedirects = false;
    if (body.isNotEmpty) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body;
    }
    try {
      final streamed = await _networkManager.send(request).timeout(const Duration(seconds: 30));
      return await http.Response.fromStream(streamed).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _emitFailure(const NexusApiError('The Nexus request timed out.', 0));
    } catch (error) {
      _emitFailure(const NexusApiError('Unable to reach Nexus Mods.', 0));
    }
    return null;
  }
}
