// Port of src/smapi/SmapiLauncher.{h,cpp}.
//
// Port note: the C++ Linux implementation used pipe + double fork + execv so the game would
// outlive the launcher and so exec failures could be reported. Dart's
// `Process.start(mode: ProcessStartMode.detached)` provides the same guarantees: the child
// is fully detached, and a failure to start throws a ProcessException synchronously from
// the Future. The argument splitter and UTF-8 handling are kept because callers still pass
// one shell-like argument string. Like the C++ version, only Linux is supported for now.

import 'dart:io';

import 'package:path/path.dart' as p;

// ------ HELPERS (START) ------

/// @brief Parses string of multiple arguments into a list of individual arguments.
///
/// Supports single and double quotes and backslash escapes, mirroring the C++ splitter.
/// @return The parsed arguments, or null when a quote is left unterminated.
List<String>? splitArguments(String arguments) {
  final result = <String>[];
  final characters = arguments.runes.map(String.fromCharCode).toList();
  bool isSpace(String character) => character.trim().isEmpty;

  // Loop through each character in arguments.
  for (var index = 0; index < characters.length;) {
    // Skip over whitespaces. Stop here if index reaches end of arguments.
    while (index < characters.length && isSpace(characters[index])) {
      ++index;
    }
    if (index == characters.length) break;

    final argument = StringBuffer();
    String? quote;

    while (index < characters.length) {
      final character = characters[index++];
      if (character == '\\' && index < characters.length) {
        argument.write(characters[index++]);
      } else if (character == "'" || character == '"') {
        if (quote == null) {
          quote = character;
        } else if (quote == character) {
          quote = null;
        } else {
          argument.write(character);
        }
      } else if (quote == null && isSpace(character)) {
        break;
      } else {
        argument.write(character);
      }
    }

    if (quote != null) return null;
    result.add(argument.toString());
  }

  return result;
}

// ------ HELPERS (END) ------

// ------ LAUNCHER (START) ------

/// @brief Starts SMAPI as a detached process so the game outlives the launcher.
class SmapiLauncher {
  const SmapiLauncher();

  /// @brief Launches `StardewModdingAPI` from [gameDirectory] with optional [arguments].
  /// @return True when the process started; false when the executable is missing, the
  /// arguments are malformed, the platform is unsupported, or the OS refused to start it.
  Future<bool> launch(String gameDirectory, [String arguments = '']) async {
    if (!Platform.isLinux) return false;

    // Only proceed if Modding API is found.
    final executable = p.join(gameDirectory, 'StardewModdingAPI');
    if (FileSystemEntity.typeSync(executable) != FileSystemEntityType.file) return false;

    // Only proceed if arguments are valid.
    final parsedArguments = splitArguments(arguments);
    if (parsedArguments == null) return false;

    try {
      // Start the Modding API from the game directory for relative paths.
      await Process.start(executable, parsedArguments,
          workingDirectory: gameDirectory, mode: ProcessStartMode.detached);
      return true;
    } on ProcessException {
      return false;
    }
  }
}

// ------ LAUNCHER (END) ------
