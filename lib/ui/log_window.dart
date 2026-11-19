// Port of src/qt/LogWindow.{h,cpp}.
//
// Port notes:
// - The Qt class was one QWidget owning both the log logic and a QTableWidget. Flutter
//   widgets are rebuilt from state, so the logic lives in `LogWindowController` (a
//   ChangeNotifier with the same method names) and `LogWindow` only draws it. The instance
//   window owns the controller so logs survive navigating away and back.
// - Selection is per row instead of per cell; copying still produces tab-separated text.
// - Qt's pixel-exact viewport restoration became "stay pinned to the bottom when the user
//   was already at the bottom", which is the behavior users notice.

import 'dart:collection';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

enum Severity { trace, debug, info, alert, warn, error, fatal }

/// @brief One retained log line.
class LogEntry {
  LogEntry(this.severity, this.source, this.message, [Duration? timestamp])
      : timestamp = timestamp ?? _timeOfDayNow();

  final Severity severity;
  final String source;
  final String message;
  // Time of day, like QTime; untimestamped lines receive their arrival time.
  final Duration timestamp;
  int sequence = 0;
}

Duration _timeOfDayNow() {
  final now = DateTime.now();
  return Duration(
      hours: now.hour, minutes: now.minute, seconds: now.second, milliseconds: now.millisecond);
}

/// @brief Formats a time of day as HH:mm:ss.zzz.
String formatTimestamp(Duration time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = time.inHours % 24;
  final minutes = time.inMinutes % 60;
  final seconds = time.inSeconds % 60;
  final milliseconds = (time.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '${two(hours)}:${two(minutes)}:${two(seconds)}.$milliseconds';
}

const int maximumEntries = 5000;
const int maximumLineLength = 16384;

// Line terminators recognized by Qt: CR, LF, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR.
bool _isLineEnd(String character) =>
    character == '\r' || character == '\n' || character == ' ' || character == ' ';

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// @brief Holds console history, parses process output, and applies filters and sorting.
class LogWindowController extends ChangeNotifier {
  final Queue<LogEntry> _entries = Queue();
  String _pendingOutput = '';
  String _lastSource = 'Game';
  Severity _lastSeverity = Severity.info;
  List<LogEntry> _visibleEntries = [];
  int _nextSequence = 0;
  int _sortColumn = 0;
  bool _sortAscending = true;
  int _lastClickedColumn = -1;
  bool _skipLineFeed = false;
  bool _fragmentedLine = false;

  Severity _minimumSeverity = Severity.trace;
  String _filterText = '';
  final Set<int> selectedSequences = {};

  // ------ read-only state for the widget and tests ------
  List<LogEntry> get visibleEntries => List.unmodifiable(_visibleEntries);
  int get sortColumn => _sortColumn;
  bool get sortAscending => _sortAscending;
  Severity get minimumSeverity => _minimumSeverity;
  String get filterText => _filterText;

  /// @brief Returns the canonical display name for a severity threshold.
  static String severityName(Severity severity) => switch (severity) {
        Severity.trace => 'TRACE',
        Severity.debug => 'DEBUG',
        Severity.info => 'INFO',
        Severity.alert => 'ALERT',
        Severity.warn => 'WARN',
        Severity.error => 'ERROR',
        Severity.fatal => 'FATAL',
      };

  /// @brief Maps supported SMAPI and BepInEx severity names to ordered levels.
  static Severity parseSeverity(String name) {
    final normalized = name.toUpperCase();
    if (normalized == 'TRACE') return Severity.trace;
    if (normalized == 'DEBUG') return Severity.debug;
    if (normalized == 'ALERT') return Severity.alert;
    if (normalized == 'WARN' || normalized == 'WARNING') return Severity.warn;
    if (normalized == 'ERROR') return Severity.error;
    if (normalized == 'FATAL' || normalized == 'CRITICAL') return Severity.fatal;
    return Severity.info;
  }

  /// @brief Returns a readable severity color on the console background.
  static Color severityColor(Severity severity) => switch (severity) {
        Severity.trace => const Color(0xFFA4AEBA),
        Severity.debug => const Color(0xFFA7C6DF),
        Severity.info => const Color(0xFFDCE3EB),
        Severity.alert => const Color(0xFFC5ADFF),
        Severity.warn => const Color(0xFFF4D17B),
        Severity.error => const Color(0xFFFF9B94),
        Severity.fatal => const Color(0xFFFF8CC6),
      };

  /// @brief Formats a physical line with explicit severity and source labels.
  static String displayText(LogEntry entry) =>
      '[${severityName(entry.severity)}] [${entry.source}] ${entry.message}';

  /// @brief Consumes process fragments, retaining incomplete lines until completion.
  void appendOutput(String output) {
    // Bound unfinished lines too, even when a process never emits a newline.
    for (var index = 0; index < output.length; ++index) {
      final character = output[index];
      if (_skipLineFeed) {
        _skipLineFeed = false;
        if (character == '\n') continue;
      }
      if (_isLineEnd(character)) {
        _consumeLine(_pendingOutput, !_fragmentedLine);
        _pendingOutput = '';
        _fragmentedLine = false;
        _skipLineFeed = character == '\r';
        continue;
      }
      if (_pendingOutput.length == maximumLineLength) {
        // Keep a UTF-16 surrogate pair together so parsing sees valid Unicode.
        var carry = '';
        if (_isHighSurrogate(_pendingOutput.codeUnitAt(_pendingOutput.length - 1)) &&
            _isLowSurrogate(character.codeUnitAt(0))) {
          carry = _pendingOutput.substring(_pendingOutput.length - 1);
          _pendingOutput = _pendingOutput.substring(0, _pendingOutput.length - 1);
        }
        _consumeLine(_pendingOutput, !_fragmentedLine);
        _pendingOutput = carry;
        _fragmentedLine = true;
      }
      _pendingOutput += character;
    }
    notifyListeners();
  }

  /// @brief Flushes the previous tail and resets attribution for a new process session.
  void beginSession() {
    flushOutput();
    _lastSource = 'Game';
    _lastSeverity = Severity.info;
    _skipLineFeed = false;
    _fragmentedLine = false;
  }

  /// @brief Displays any unfinished output without an empty trailing line.
  void flushOutput() {
    if (_pendingOutput.isNotEmpty) {
      _consumeLine(_pendingOutput, !_fragmentedLine);
      _pendingOutput = '';
      notifyListeners();
    }
    _fragmentedLine = false;
  }

  /// @brief Appends plain-text launcher messages with the supplied severity and source.
  void appendMessage(String message,
      [Severity severity = Severity.info, String source = 'Launcher']) {
    var safeSource = source.replaceAll(RegExp('[\r\n  ]'), ' ');
    if (safeSource.isEmpty) safeSource = 'Launcher';
    if (safeSource.length > maximumLineLength) {
      safeSource = safeSource.substring(0, maximumLineLength);
    }

    var line = '';
    var skipLineFeed = false;
    for (var index = 0; index < message.length; ++index) {
      final character = message[index];
      if (skipLineFeed) {
        skipLineFeed = false;
        if (character == '\n') continue;
      }
      if (_isLineEnd(character)) {
        _appendEntry(LogEntry(severity, safeSource, line));
        line = '';
        skipLineFeed = character == '\r';
        continue;
      }
      if (line.length == maximumLineLength) {
        var carry = '';
        if (_isHighSurrogate(line.codeUnitAt(line.length - 1)) &&
            _isLowSurrogate(character.codeUnitAt(0))) {
          carry = line.substring(line.length - 1);
          line = line.substring(0, line.length - 1);
        }
        _appendEntry(LogEntry(severity, safeSource, line));
        line = carry;
      }
      line += character;
    }
    if (line.isNotEmpty || message.isEmpty) _appendEntry(LogEntry(severity, safeSource, line));
    notifyListeners();
  }

  static final RegExp _timestampPrefix = RegExp(
      r'^\[\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\s+(TRACE|DEBUG|INFO|MESSAGE|ALERT|WARN|WARNING|ERROR|FATAL|CRITICAL|SUCCESS)\s+(?:screen_\d+\s+)?([^\]]+)\] ?(.*)$',
      caseSensitive: false);
  static final RegExp _bepinexPrefix = RegExp(
      r'^\[(TRACE|DEBUG|INFO|MESSAGE|ALERT|WARN|WARNING|ERROR|FATAL|CRITICAL|SUCCESS)\s*:\s*([^\]]+)\] ?(.*)$',
      caseSensitive: false);
  static final RegExp _sourcePrefix = RegExp(r'^\[([^\]]+)\] ?(.*)$');

  /// @brief Parses a completed stream line, inheriting metadata for continuations.
  void _consumeLine(String line, bool parsePrefix) {
    var message = line;
    var timestamp = _timeOfDayNow();
    if (parsePrefix) {
      var match = _timestampPrefix.firstMatch(line);
      if (match != null) {
        // SMAPI prefixes look like "[12:34:56 INFO  Mod Name] message".
        final timeText = line.substring(1, line.indexOf(match.group(1)!, 1)).trim();
        final timeParts = timeText.split('.');
        final clock = timeParts.first.split(':').map(int.tryParse).toList();
        final milliseconds =
            timeParts.length > 1 ? int.parse(timeParts[1].padRight(3, '0').substring(0, 3)) : 0;
        if (clock.length == 3 &&
            clock.every((part) => part != null) &&
            clock[0]! < 24 &&
            clock[1]! < 60 &&
            clock[2]! < 60) {
          timestamp = Duration(
              hours: clock[0]!, minutes: clock[1]!, seconds: clock[2]!, milliseconds: milliseconds);
        }
      }
      match ??= _bepinexPrefix.firstMatch(line);
      if (match != null) {
        _lastSeverity = parseSeverity(match.group(1)!);
        _lastSource = match.group(2)!.trim();
        message = match.group(3)!;
      } else {
        final sourceMatch = _sourcePrefix.firstMatch(line);
        if (sourceMatch != null) {
          _lastSeverity = Severity.info;
          _lastSource = sourceMatch.group(1)!.trim();
          message = sourceMatch.group(2)!;
        }
      }
    }
    if (_lastSource.isEmpty) _lastSource = 'Game';
    _appendEntry(LogEntry(_lastSeverity, _lastSource, message, timestamp));
  }

  /// @brief Retains one bounded entry and incrementally updates the visible rows.
  void _appendEntry(LogEntry entry) {
    entry.sequence = _nextSequence++;
    // Expiration follows arrival order even when the table has another sort order.
    if (_entries.length == maximumEntries) {
      _removeVisibleEntry(_entries.first.sequence);
      _entries.removeFirst();
    }
    _entries.addLast(entry);
    if (_matchesFilters(entry)) _appendVisibleEntry(entry);
  }

  /// @brief Returns true for entries satisfying both filters, or false otherwise.
  bool _matchesFilters(LogEntry entry) {
    if (entry.severity.index < _minimumSeverity.index) return false;
    final query = _filterText.toLowerCase();
    return query.isEmpty || displayText(entry).toLowerCase().contains(query);
  }

  /// @brief Returns true when left precedes right under the active sort and arrival tie
  /// break.
  bool _entryPrecedes(LogEntry left, LogEntry right) {
    final comparison = switch (_sortColumn) {
      0 => left.timestamp.compareTo(right.timestamp),
      1 => left.severity.index - right.severity.index,
      2 => left.source.toLowerCase().compareTo(right.source.toLowerCase()),
      _ => left.message.toLowerCase().compareTo(right.message.toLowerCase()),
    };
    // Arrival ties stay stable in both directions rather than reversing with the key.
    if (comparison == 0) return left.sequence < right.sequence;
    return _sortAscending ? comparison < 0 : comparison > 0;
  }

  /// @brief Inserts a row in the active sort order (binary search, like std::lower_bound).
  void _appendVisibleEntry(LogEntry entry) {
    var low = 0;
    var high = _visibleEntries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_entryPrecedes(_visibleEntries[middle], entry)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    _visibleEntries.insert(low, entry);
  }

  /// @brief Removes the row for an expired retained entry, if it is visible.
  void _removeVisibleEntry(int sequence) {
    _visibleEntries.removeWhere((entry) => entry.sequence == sequence);
    selectedSequences.remove(sequence);
  }

  /// @brief Rebuilds filtered and sorted history; selection survives when rows stay visible.
  void _rebuildVisibleEntries() {
    _visibleEntries = [];
    for (final entry in _entries) {
      if (_matchesFilters(entry)) _appendVisibleEntry(entry);
    }
    final visible = _visibleEntries.map((entry) => entry.sequence).toSet();
    selectedSequences.removeWhere((sequence) => !visible.contains(sequence));
    notifyListeners();
  }

  /// @brief Cycles a header sort: ascending, descending, then back to chronological.
  void sortByColumn(int column) {
    if (_lastClickedColumn != column) {
      _sortColumn = column;
      _sortAscending = true;
    } else if (_sortAscending) {
      _sortAscending = false;
    } else if (column == 0) {
      _sortAscending = true;
    } else {
      _sortColumn = 0;
      _sortAscending = true;
    }
    _lastClickedColumn = _sortColumn == column ? column : -1;
    _rebuildVisibleEntries();
  }

  /// @brief Changes the minimum severity filter.
  void setMinimumSeverity(Severity severity) {
    _minimumSeverity = severity;
    _rebuildVisibleEntries();
  }

  /// @brief Changes the case-insensitive text filter.
  void setFilterText(String text) {
    _filterText = text;
    _rebuildVisibleEntries();
  }

  /// @brief Returns selected visible rows as tab-separated text, one row per line.
  String selectionText() {
    final rows = <String>[];
    for (final entry in _visibleEntries) {
      if (!selectedSequences.contains(entry.sequence)) continue;
      rows.add([
        formatTimestamp(entry.timestamp),
        severityName(entry.severity),
        entry.source,
        entry.message,
      ].join('\t'));
    }
    return rows.join('\n');
  }

  /// @brief Copies selected visible rows to the clipboard.
  Future<void> copySelection() async {
    final text = selectionText();
    if (text.isNotEmpty) await Clipboard.setData(ClipboardData(text: text));
  }

  /// @brief Selects one row, or toggles it when [extend] is true (Ctrl/Shift-click).
  void selectRow(int sequence, {bool extend = false}) {
    if (!extend) selectedSequences.clear();
    if (!selectedSequences.remove(sequence)) selectedSequences.add(sequence);
    notifyListeners();
  }

  /// @brief Clears history, unfinished output, and inherited stream metadata.
  void clearHistory() {
    _entries.clear();
    _pendingOutput = '';
    _lastSource = 'Game';
    _lastSeverity = Severity.info;
    _skipLineFeed = false;
    _fragmentedLine = false;
    _visibleEntries = [];
    selectedSequences.clear();
    notifyListeners();
  }
}

/// @brief Console view: severity slider, text filter, sortable table, and copy support.
class LogWindow extends StatefulWidget {
  const LogWindow({super.key, required this.controller});

  final LogWindowController controller;

  @override
  State<LogWindow> createState() => _LogWindowState();
}

class _LogWindowState extends State<LogWindow> {
  static const _consoleBackground = Color(0xFF15191F);
  static const _gridColor = Color(0xFF424B57);
  static const _rowHeight = 24.0;
  static const _columnWidths = [120.0, 85.0, 160.0];

  final ScrollController _scroll = ScrollController();
  final TextEditingController _filter = TextEditingController();
  // Clicking a row focuses the table so Ctrl+C / Cmd+C reach its shortcuts.
  final FocusNode _tableFocus = FocusNode(debugLabel: 'logs');
  bool _followEnd = true;

  @override
  void initState() {
    super.initState();
    _filter.text = widget.controller.filterText;
    widget.controller.addListener(_onLogsChanged);
    _scroll.addListener(() {
      // Following the end stops when the user scrolls up and resumes at the bottom.
      if (_scroll.hasClients) {
        _followEnd = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 4;
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onLogsChanged);
    _scroll.dispose();
    _filter.dispose();
    _tableFocus.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    setState(() {});
    if (!_followEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Widget _header(int column, String label) {
    final controller = widget.controller;
    final isSorted = controller.sortColumn == column;
    final arrow = isSorted ? (controller.sortAscending ? ' ▲' : ' ▼') : '';
    return InkWell(
      key: ValueKey('logHeader$column'),
      onTap: () => controller.sortByColumn(column),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Text('$label$arrow',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _cell(String text, Color color, double? width) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 13)),
    );
    return width == null ? Expanded(child: child) : SizedBox(width: width, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final threshold = LogWindowController.severityName(controller.minimumSeverity);
    final rows = controller.visibleEntries;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            SizedBox(
                width: 175,
                child: Text('Minimum severity: $threshold', key: const ValueKey('thresholdLabel'))),
            Expanded(
              child: Tooltip(
                message: 'Trace → Debug → Info → Alert → Warn → Error → Fatal',
                child: Slider(
                  key: const ValueKey('severitySlider'),
                  value: controller.minimumSeverity.index.toDouble(),
                  min: 0,
                  max: (Severity.values.length - 1).toDouble(),
                  divisions: Severity.values.length - 1,
                  label: threshold,
                  semanticFormatterCallback: (_) => 'Show $threshold and higher severity messages',
                  onChanged: (value) =>
                      controller.setMinimumSeverity(Severity.values[value.round()]),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: TextField(
                key: const ValueKey('logFilter'),
                controller: _filter,
                decoration: InputDecoration(
                  hintText: 'Search messages or mod names…',
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: 'Clear filter',
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () {
                      _filter.clear();
                      controller.setFilterText('');
                    },
                  ),
                ),
                onChanged: controller.setFilterText,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const ValueKey('clearLogs'),
              onPressed: controller.clearHistory,
              child: const Text('Clear'),
            ),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyC, control: true):
                    controller.copySelection,
                const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
                    controller.copySelection,
              },
              child: Focus(
                focusNode: _tableFocus,
                child: Container(
                  decoration: BoxDecoration(
                    color: _consoleBackground,
                    border: Border.all(color: _gridColor),
                  ),
                  child: Column(children: [
                    Container(
                      color: const Color(0xFF30363B),
                      child: Row(children: [
                        SizedBox(width: _columnWidths[0], child: _header(0, 'Timestamp')),
                        SizedBox(width: _columnWidths[1], child: _header(1, 'Level')),
                        SizedBox(width: _columnWidths[2], child: _header(2, 'Source')),
                        Expanded(child: _header(3, 'Message')),
                      ]),
                    ),
                    Expanded(
                      child: Semantics(
                        label: 'Game and mod log output',
                        child: ListView.builder(
                          key: const ValueKey('logs'),
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          itemCount: rows.length,
                          itemBuilder: (context, index) => _buildRow(rows[index]),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text('Latest 5,000 lines retained • Filters apply to retained history'),
        ],
      ),
    );
  }

  Widget _buildRow(LogEntry entry) {
    final controller = widget.controller;
    final color = LogWindowController.severityColor(entry.severity);
    final selected = controller.selectedSequences.contains(entry.sequence);
    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(details.globalPosition),
      child: InkWell(
        onTap: () {
          _tableFocus.requestFocus();
          final keys = HardwareKeyboard.instance;
          controller.selectRow(entry.sequence,
              extend: keys.isControlPressed || keys.isMetaPressed || keys.isShiftPressed);
        },
        child: Container(
          color: selected ? const Color(0xFF375A7F) : null,
          decoration: null,
          child: Row(children: [
            _cell(formatTimestamp(entry.timestamp), color, _columnWidths[0]),
            _cell(LogWindowController.severityName(entry.severity), color, _columnWidths[1]),
            _cell(entry.source, color, _columnWidths[2]),
            _cell(entry.message, color, null),
          ]),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(Offset position) async {
    final controller = widget.controller;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: controller.selectedSequences.isNotEmpty,
          child: const Text('Copy'),
        ),
      ],
    );
    if (choice == 'copy') await controller.copySelection();
  }
}
