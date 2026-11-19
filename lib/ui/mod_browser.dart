// Port of src/qt/ModBrowser.{h,cpp}.
//
// Presentation only: requests are connected by the owning NexusPage.
//
// Port notes:
// - Qt widgets were mutated directly (setText/show/hide). Here `ModBrowserController` keeps
//   the same public methods and stores the resulting display state; `ModBrowser` draws it.
// - Qt signals (refreshRequested, previousPageRequested, nextPageRequested, modSelected)
//   became callback fields on the controller that NexusPage assigns.
// - QSplitter became a Row with two flexible panes (2:3, like setStretchFactor).

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../nexus_fetch_list/nexus_fetch_list.dart';
import 'style.dart';

/// @brief Formats an integer with thousands separators, standing in for QLocale::toString.
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var index = 0; index < digits.length; ++index) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

/// @brief Converts Nexus HTML/BBCode descriptions to readable plain text.
String readableDescription(String text) {
  // Nexus uses BBCode as well as HTML. Match known tags so mod names such as [CP] survive.
  final listTags = RegExp(r'\[/?list(?:=[^\]\r\n]*)?\]', caseSensitive: false);
  final itemTag = RegExp(r'\n?\[\*\]');
  final formattingTags = RegExp(
      r'\[/?(?:b|i|u|s|strike|size|font|color|center|left|right|justify|url|img|quote|code|spoiler|heading|youtube|video|table|tr|td|th)(?:=[^\]\r\n]*)?\]',
      caseSensitive: false);
  final htmlTag = RegExp(r'<[A-Za-z][^>]*>');

  var plain = text;
  if (htmlTag.hasMatch(text)) {
    // Port note: QTextDocumentFragment::fromHtml did full HTML parsing. This keeps the
    // parts that matter for descriptions: line breaks, paragraphs, list items, entities.
    plain = plain
        .replaceAll(RegExp(r'\r?\n'), ' ')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|h[1-6]|li|tr)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }
  plain = plain.replaceAll(listTags, '\n');
  plain = plain.replaceAll(itemTag, '\n• ');
  plain = plain.replaceAll(formattingTags, '');
  return plain;
}

class ModBrowserController extends ChangeNotifier {
  ModBrowserController() {
    setPagination(0, 0, 0, false);
    _clearDetailsState();
  }

  // ------ signals (assigned by the owner) ------
  VoidCallback? refreshRequested;
  VoidCallback? previousPageRequested;
  VoidCallback? nextPageRequested;
  // Zero means selection was cleared; the owner should cancel outstanding details.
  void Function(int id)? modSelected;

  // ------ display state ------
  List<NexusModSummary> mods = [];
  List<NexusModSummary> filtered = [];
  int selectedId = 0;
  String searchText = '';
  bool searchEnabled = true;
  bool refreshEnabled = true;
  String refreshText = 'Refresh';
  String count = 'RECENTLY UPDATED';
  String status = '';
  String pageCount = '';
  bool previousEnabled = false;
  bool nextEnabled = false;
  String title = '';
  String? author;
  String? metadata;
  String summary = '';
  String? description;
  String? detailStatus;
  bool downloadEnabled = false;
  String downloadTooltip = '';
  // Incremented to ask the view to scroll the detail pane back to the top.
  int detailScrollResets = 0;

  void _clearDetailsState() {
    selectedId = 0;
    title = 'No mod selected';
    author = null;
    metadata = null;
    summary = 'Select a mod to view its description and download page.';
    description = null;
    detailStatus = null;
    downloadEnabled = false;
    downloadTooltip = 'Select a mod to open its download page.';
  }

  /// @brief Resets the detail pane and tells the owner that no mod is selected.
  void clearDetails() {
    _clearDetailsState();
    modSelected?.call(0);
    notifyListeners();
  }

  /// @brief Shows the first-load state: empty list, disabled controls, loading status.
  void beginLoading() {
    mods = [];
    filtered = [];
    _clearDetailsState();
    modSelected?.call(0);
    refreshEnabled = false;
    refreshText = 'Refreshing…';
    searchEnabled = false;
    count = 'RECENTLY UPDATED';
    status = 'Loading recently updated mods…';
    notifyListeners();
  }

  /// @brief Updates the "1–50 of N mods" label and the Previous/Next buttons.
  void setPagination(int offset, int total, int count, bool loading) {
    previousEnabled = !loading && offset > 0;
    nextEnabled = !loading && count > 0 && offset + count < total;
    pageCount = count > 0
        ? '${formatCount(offset + 1)}–${formatCount(offset + count)} of ${formatCount(total)} mods'
        : '0 mods on this page';
    notifyListeners();
  }

  /// @brief Keeps the current page visible while another page loads.
  void beginPageLoading() {
    refreshEnabled = false;
    refreshText = 'Loading…';
    searchEnabled = false;
    previousEnabled = false;
    nextEnabled = false;
    status = 'Loading mod page…';
    notifyListeners();
  }

  /// @brief Reports a page error while leaving the current page usable.
  void setPageError(String message) {
    refreshEnabled = true;
    refreshText = 'Refresh';
    searchEnabled = true;
    status = message;
    notifyListeners();
  }

  /// @brief Replaces the list with a new page of mods.
  void setMods(List<NexusModSummary> newMods) {
    _clearDetailsState();
    modSelected?.call(0);
    mods = List.of(newMods);
    refreshEnabled = true;
    refreshText = 'Refresh';
    searchEnabled = true;
    filterMods();
  }

  /// @brief Shows a list-level error with actionable guidance.
  void setListError(String message) {
    setMods([]);
    // Keep actionable API/connection guidance visible until the user retries.
    searchEnabled = false;
    status = message;
    title = 'Mod list unavailable';
    summary = 'Once the mod list is available, select a name to explore it here.';
    notifyListeners();
  }

  /// @brief Changes the search text and refilters the current page.
  void setSearchText(String text) {
    searchText = text;
    filterMods();
  }

  /// @brief Applies the search filter, keeping the selection when it is still visible.
  void filterMods() {
    final previousId = selectedId;
    filtered = NexusModClient.searchMods(mods, searchText);
    count = '${filtered.length} OF ${mods.length} MODS';
    status = mods.isEmpty
        ? 'No mods returned. Try refreshing in a moment.'
        : filtered.isEmpty
            ? 'No matching mods on this page. Try a different filter.'
            : 'Select a name to explore.';
    final stillVisible = previousId > 0 && filtered.any((mod) => mod.id == previousId);
    if (!stillVisible) {
      clearDetails();
    } else {
      notifyListeners();
    }
  }

  void _showSummary(NexusModSummary mod) {
    title = mod.name;
    author = mod.author.isEmpty ? 'Author not listed' : 'By ${mod.author}';
    metadata = 'Version ${mod.version.isEmpty ? 'not listed' : mod.version}  ·  '
        '${formatCount(mod.endorsementCount)} endorsements';
    summary = mod.summary.isEmpty ? 'No summary provided.' : mod.summary;
  }

  /// @brief Selects a mod from the list and asks the owner to fetch its details.
  void selectMod(int id) {
    for (final mod in mods) {
      if (mod.id != id) continue;
      selectedId = id;
      _showSummary(mod);
      description = null;
      detailStatus = 'Loading full details…';
      downloadEnabled = selectedId > 0;
      downloadTooltip = "View this mod's Files tab on Nexus Mods.";
      detailScrollResets++;
      modSelected?.call(selectedId);
      notifyListeners();
      return;
    }
    clearDetails();
  }

  /// @brief Shows full details when they belong to the current selection.
  void setModDetails(NexusModDetails mod) {
    if (selectedId <= 0 || mod.id != selectedId) return;
    _showSummary(mod);
    // Strip API HTML without enabling rich text or links in the label.
    final text = readableDescription(mod.description);
    description = text.isEmpty ? 'No additional description provided.' : text;
    var details = '${metadata!}\n${formatCount(mod.downloadCount)} downloads';
    final updated = mod.updatedAt;
    if (updated != null) {
      final local = updated.toLocal();
      details += '  ·  Updated ${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
    }
    metadata = details;
    detailStatus = mod.available ? null : 'This mod is currently unavailable on Nexus Mods.';
    downloadEnabled = mod.available;
    if (!mod.available) downloadTooltip = 'This mod is currently unavailable.';
    notifyListeners();
  }

  /// @brief Reports a details failure; the download page remains available.
  void setDetailsError(String message) {
    if (selectedId <= 0) return;
    detailStatus =
        'Full details could not be loaded. $message You can still visit the download page.';
    notifyListeners();
  }

  /// @brief Opens the selected mod's Files tab in the browser.
  Future<void> openDownloadPage() async {
    if (selectedId <= 0 || !downloadEnabled) return;
    // Build an HTTPS destination from the ID, never from untrusted API text.
    final url = Uri.parse('https://www.nexusmods.com/stardewvalley/mods/$selectedId?tab=files');
    bool opened;
    try {
      opened = await launchUrl(url);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      detailStatus = 'Could not open your browser. Please try again.';
      notifyListeners();
    }
  }
}

class ModBrowser extends StatefulWidget {
  const ModBrowser({super.key, required this.controller});

  final ModBrowserController controller;

  @override
  State<ModBrowser> createState() => _ModBrowserState();
}

class _ModBrowserState extends State<ModBrowser> {
  final ScrollController _details = ScrollController();
  final TextEditingController _search = TextEditingController();
  int _lastScrollReset = 0;

  @override
  void dispose() {
    _details.dispose();
    _search.dispose();
    super.dispose();
  }

  Widget _label(String? text, String name, TextStyle style) {
    if (text == null) return const SizedBox.shrink();
    return SelectableText(text, key: ValueKey(name), style: style);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        if (_lastScrollReset != c.detailScrollResets) {
          _lastScrollReset = c.detailScrollResets;
          if (_details.hasClients) _details.jumpTo(0);
        }
        return Padding(
          key: const ValueKey('modBrowser'),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Nexus mods', style: LauncherText.sectionTitle),
                  SizedBox(height: 4),
                  Text('Recently updated on Nexus Mods · Stardew Valley',
                      style: LauncherText.muted),
                ]),
              ),
              Tooltip(
                message: 'Reload the first page of recently updated Stardew Valley mods.',
                child: TextButton(
                  key: const ValueKey('modRefresh'),
                  onPressed: c.refreshEnabled ? c.refreshRequested : null,
                  child: Text(c.refreshText),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(flex: 2, child: _buildMaster(c)),
                const SizedBox(width: 8),
                Expanded(flex: 3, child: _buildDetails(c)),
              ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildMaster(ModBrowserController c) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const ValueKey('modSearch'),
        controller: _search,
        enabled: c.searchEnabled,
        decoration: const InputDecoration(hintText: 'Filter this page…'),
        onChanged: c.setSearchText,
      ),
      const SizedBox(height: 12),
      Text(c.count, key: const ValueKey('modCount'), style: LauncherText.eyebrow),
      const SizedBox(height: 12),
      Expanded(
        // A Material (not a colored Container) so ListTile selection highlights stay visible.
        child: Material(
          color: LauncherColors.panel,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: LauncherColors.border),
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListView.builder(
            key: const ValueKey('modList'),
            itemCount: c.filtered.length,
            itemBuilder: (context, index) {
              final mod = c.filtered[index];
              return ListTile(
                key: ValueKey('mod-${mod.id}'),
                dense: true,
                title: Text(mod.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                selected: mod.id == c.selectedId,
                onTap: () => c.selectMod(mod.id),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(c.pageCount, key: const ValueKey('modPageCount'), style: LauncherText.muted),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('modPrevious'),
            onPressed: c.previousEnabled ? c.previousPageRequested : null,
            child: const Text('Previous'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('modNext'),
            onPressed: c.nextEnabled ? c.nextPageRequested : null,
            child: const Text('Next'),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Text(c.status, key: const ValueKey('modListStatus'), style: LauncherText.muted),
    ]);
  }

  Widget _buildDetails(ModBrowserController c) {
    return Container(
      key: const ValueKey('modDetailPanel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: LauncherColors.panel,
        border: Border.all(color: LauncherColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: SingleChildScrollView(
            controller: _details,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('MOD DETAILS', style: LauncherText.eyebrow),
              const SizedBox(height: 16),
              _label(c.title, 'modTitle', LauncherText.detailTitle),
              const SizedBox(height: 8),
              _label(
                  c.author, 'modAuthor', const TextStyle(color: Color(0xFF555C61), fontSize: 13)),
              const SizedBox(height: 8),
              _label(c.metadata, 'modMetadata', LauncherText.muted),
              const SizedBox(height: 16),
              _label(
                  c.summary, 'modSummary', const TextStyle(color: Color(0xFF41474B), fontSize: 14)),
              const SizedBox(height: 16),
              _label(c.description, 'modDescription',
                  const TextStyle(color: Color(0xFF555C61), fontSize: 13)),
              const SizedBox(height: 8),
              _label(c.detailStatus, 'modDetailStatus', LauncherText.muted),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Downloads open in your browser. Nothing is installed automatically.',
            style: LauncherText.muted),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Tooltip(
            message: c.downloadTooltip,
            child: FilledButton(
              key: const ValueKey('modDownload'),
              onPressed: c.downloadEnabled ? c.openDownloadPage : null,
              child: const Text('Open download page  ↗'),
            ),
          ),
        ),
      ]),
    );
  }
}
