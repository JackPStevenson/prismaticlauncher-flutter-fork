// Port note: the C++ code relied on nlohmann::json's `ignore_comments` option and a manual
// comment/trailing-comma normalizer. Dart's `jsonDecode` is strict, so both behaviors live
// here and are shared by the SMAPI detector and the mod installer.

/// @brief Replaces `//` and `/* */` comments outside quoted strings with spaces.
///
/// Quoted strings are preserved exactly, including URLs and text that contains `//` or `/*`.
/// Replacing with spaces (rather than deleting) keeps character offsets stable for errors.
/// @return The text without comments, or null when a block comment is unterminated.
String? stripJsonComments(String text) {
  final characters = text.split('');
  var quoted = false;
  for (var i = 0; i < characters.length; ++i) {
    final character = characters[i];
    if (quoted) {
      if (character == '\\') {
        ++i;
      } else if (character == '"') {
        quoted = false;
      }
    } else if (character == '"') {
      quoted = true;
    } else if (character == '/' && i + 1 < characters.length) {
      final isLineComment = characters[i + 1] == '/';
      final isBlockComment = characters[i + 1] == '*';
      if (!isLineComment && !isBlockComment) continue;
      var end = isLineComment ? text.indexOf('\n', i + 2) : text.indexOf('*/', i + 2);
      if (end < 0 && isBlockComment) return null;
      end = end < 0 ? characters.length : end + (isBlockComment ? 2 : 0);
      while (i < end) {
        characters[i++] = ' ';
      }
      --i;
    }
  }
  return characters.join();
}

/// @brief Replaces commas that directly precede `}` or `]` (outside strings) with spaces.
String stripTrailingCommas(String text) {
  final characters = text.split('');
  var quoted = false;
  for (var i = 0; i < characters.length; ++i) {
    final character = characters[i];
    if (quoted) {
      if (character == '\\') {
        ++i;
      } else if (character == '"') {
        quoted = false;
      }
    } else if (character == '"') {
      quoted = true;
    } else if (character == ',') {
      var next = i + 1;
      while (next < characters.length && ' \t\r\n'.contains(characters[next])) {
        ++next;
      }
      if (next < characters.length && (characters[next] == '}' || characters[next] == ']')) {
        characters[i] = ' ';
      }
    }
  }
  return characters.join();
}
