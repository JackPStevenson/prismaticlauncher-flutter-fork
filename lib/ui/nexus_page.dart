// Port of src/qt/NexusPage.{h,cpp}.
//
// Connects a NexusModClient (network) to a ModBrowser (presentation) and tracks paging.

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;

import '../nexus_fetch_list/nexus_fetch_list.dart';
import 'mod_browser.dart';

class NexusPage extends StatefulWidget {
  const NexusPage({
    super.key,
    this.showBack = true,
    this.networkManager,
    this.apiKey,
    this.onBackRequested,
    this.fetchOnStart = true,
  });

  final bool showBack;
  // An injected client (tests use MockClient) is borrowed and never closed here.
  final http.Client? networkManager;
  // Defaults to the NEXUS_API_KEY environment variable, like qEnvironmentVariable.
  final String? apiKey;
  // Replaces the Qt backRequested signal.
  final VoidCallback? onBackRequested;
  // Qt called fetchMods() when the page was first shown; Flutter does it on first build.
  final bool fetchOnStart;

  @override
  State<NexusPage> createState() => NexusPageState();
}

class NexusPageState extends State<NexusPage> {
  int _offset = 0;
  int _requestedOffset = 0;
  int _totalCount = 0;
  int _returnedCount = 0;
  bool _hasPage = false;
  bool _loading = false;
  late final String _apiKey;
  late final bool _missingKey;
  late final NexusModClient _client;
  NexusModClient? _detailsClient;
  final ModBrowserController browser = ModBrowserController();
  final List<StreamSubscription<Object>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _apiKey = widget.apiKey ?? Platform.environment['NEXUS_API_KEY'] ?? '';
    _missingKey = _apiKey.trim().isEmpty;
    _client = NexusModClient(_apiKey, networkManager: widget.networkManager);

    browser
      ..refreshRequested = fetchMods
      ..previousPageRequested = () {
        if (_offset > 0) _requestPage((_offset - NexusModClient.pageSize).clamp(0, _offset));
      }
      ..nextPageRequested = () {
        if (_returnedCount > 0 && _offset + _returnedCount < _totalCount) {
          _requestPage(_offset + _returnedCount);
        }
      }
      ..modSelected = _fetchDetails;

    _subscriptions.add(_client.modPageFetched.listen((page) {
      if (page.offset != _requestedOffset) return;
      _loading = false;
      _hasPage = true;
      _offset = page.offset;
      _returnedCount = page.mods.length;
      _totalCount = page.totalCount;
      browser.setMods(page.mods);
      _updatePagination();
    }));
    _subscriptions.add(_client.requestFailed.listen((error) {
      _loading = false;
      final String message;
      if (_missingKey && error.httpStatus == 0) {
        message = "Set NEXUS_API_KEY in the launcher's environment, then restart the launcher.";
      } else if (error.httpStatus >= 400) {
        message =
            'Unable to load mod page (HTTP ${error.httpStatus}). Check your API key or retry.';
      } else {
        message = '${error.message} Check your connection and API key, then retry.';
      }
      if (_hasPage) {
        browser.setPageError('$message Your current page is still available.');
      } else {
        browser.setListError(message);
      }
      _updatePagination();
    }));

    if (widget.fetchOnStart) fetchMods();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _detailsClient?.dispose();
    _client.dispose();
    browser.dispose();
    super.dispose();
  }

  /// @brief Loads the first page of mods.
  void fetchMods() => _requestPage(0);

  /// @brief Fetches details for [id], cancelling any previous details request.
  void _fetchDetails(int id) {
    // A new selection or refresh cancels the previous detail request.
    _detailsClient?.dispose();
    _detailsClient = null;
    if (id <= 0) return;
    final details = NexusModClient(_apiKey, networkManager: widget.networkManager);
    _detailsClient = details;
    details.modDetailsFetched.listen(browser.setModDetails);
    details.requestFailed.listen((error) => browser.setDetailsError(error.message));
    details.fetchModDetails(id);
  }

  void _requestPage(int offset) {
    if (_loading) return;
    _loading = true;
    _requestedOffset = offset;
    if (_hasPage) {
      browser.beginPageLoading();
    } else {
      browser.beginLoading();
    }
    _updatePagination();
    _client.fetchModPage(offset);
  }

  void _updatePagination() => browser.setPagination(_offset, _totalCount, _returnedCount, _loading);

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('nexusPage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showBack)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('backFromNexus'),
                onPressed: widget.onBackRequested,
                child: const Text('←  Back to library'),
              ),
            ),
          ),
        Expanded(child: ModBrowser(controller: browser)),
      ],
    );
  }
}
