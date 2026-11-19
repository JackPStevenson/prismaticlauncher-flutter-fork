// Replacement for QSettings(..., QSettings::IniFormat).
//
// Qt shipped an INI reader/writer; Flutter does not. This minimal implementation reads and
// writes the same `[section]` / `key=value` layout, so a launcher.ini written by the Qt
// build can be opened by the Flutter build and vice versa. Keys are addressed as
// "section/key", exactly like the C++ code (for example "game/directory").

import 'dart:io';

class IniFile {
  /// @brief Loads [filePath] immediately; a missing or unreadable file starts empty.
  IniFile(this.filePath) {
    _load();
  }

  final String filePath;

  // Section name -> (key -> raw value). Insertion order is kept so saves are stable.
  final Map<String, Map<String, String>> _sections = {};

  void _load() {
    final List<String> lines;
    try {
      lines = File(filePath).readAsLinesSync();
    } on FileSystemException {
      return;
    }
    var section = 'General';
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim();
        continue;
      }
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      var value = line.substring(separator + 1).trim();
      // QSettings quotes values that contain special characters; strip those quotes.
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1).replaceAll(r'\"', '"').replaceAll(r'\\', '\\');
      }
      _sections.putIfAbsent(section, () => {})[key] = value;
    }
  }

  (String, String) _split(String key) {
    final slash = key.indexOf('/');
    return slash < 0 ? ('General', key) : (key.substring(0, slash), key.substring(slash + 1));
  }

  /// @brief Returns true when "section/key" has a stored value.
  bool contains(String key) {
    final (section, name) = _split(key);
    return _sections[section]?.containsKey(name) ?? false;
  }

  /// @brief Returns the raw string for "section/key", or [fallback] when absent.
  String? value(String key, [String? fallback]) {
    final (section, name) = _split(key);
    return _sections[section]?[name] ?? fallback;
  }

  /// @brief Reads "section/key" as a boolean using QSettings' "true"/"false" spelling.
  bool boolValue(String key, bool fallback) {
    final raw = value(key);
    if (raw == null) return fallback;
    return raw.toLowerCase() == 'true' || raw == '1';
  }

  /// @brief Reads "section/key" as an integer, or [fallback] when absent or malformed.
  int intValue(String key, int fallback) => int.tryParse(value(key) ?? '') ?? fallback;

  /// @brief Stores a value in memory; call [sync] to write it to disk.
  void setValue(String key, Object value) {
    final (section, name) = _split(key);
    _sections.putIfAbsent(section, () => {})[name] = value.toString();
  }

  /// @brief Removes "section/key" from memory; call [sync] to write the change.
  void remove(String key) {
    final (section, name) = _split(key);
    _sections[section]?.remove(name);
  }

  /// @brief Writes every section to disk.
  /// @return True after a successful write, or false when the file cannot be written.
  bool sync() {
    final buffer = StringBuffer();
    for (final MapEntry(key: section, value: entries) in _sections.entries) {
      if (entries.isEmpty) continue;
      buffer.writeln('[$section]');
      for (final MapEntry(:key, :value) in entries.entries) {
        buffer.writeln('$key=$value');
      }
      buffer.writeln();
    }
    try {
      File(filePath).writeAsStringSync(buffer.toString(), flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
