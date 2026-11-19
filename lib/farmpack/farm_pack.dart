// Port of src/farmpack/FarmPack.{h,cpp}.
//
// A FarmPack is a JSON manifest that names a default image plus seasonal variants with
// MM-DD date ranges. Image paths must stay inside the manifest's folder.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/error_message.dart';

/// @brief A month/day pair; the year is irrelevant for seasonal matching.
///
/// Port note: the C++ code stored these as QDate values in the leap year 2000. Comparing
/// `month * 100 + day` gives the same ordering without a calendar type.
class MonthDay implements Comparable<MonthDay> {
  const MonthDay(this.month, this.day);

  final int month;
  final int day;

  int get _ordinal => month * 100 + day;

  @override
  int compareTo(MonthDay other) => _ordinal.compareTo(other._ordinal);

  bool operator <=(MonthDay other) => _ordinal <= other._ordinal;
  bool operator >=(MonthDay other) => _ordinal >= other._ordinal;
}

/// @brief One seasonal image shown between [start] and [end], inclusive.
class FarmPackVariant {
  MonthDay start = const MonthDay(1, 1);
  MonthDay end = const MonthDay(1, 1);
  String imagePath = '';

  /// @brief Returns true when [date]'s month and day fall within this variant's range.
  ///
  /// Ranges whose end precedes their start wrap across the new year (for example 12-01 to
  /// 02-28).
  bool matches(DateTime date) {
    final day = MonthDay(date.month, date.day);
    if (start <= end) return day >= start && day <= end;
    return day >= start || day <= end;
  }
}

class FarmPack {
  String name = '';
  String defaultImagePath = '';
  final List<FarmPackVariant> variants = [];

  /// @brief Returns the first matching variant's image, or the default image.
  String imageForDate(DateTime date) {
    for (final variant in variants) {
      if (variant.matches(date)) return variant.imagePath;
    }
    return defaultImagePath;
  }

  /// @brief Reads and validates a FarmPack manifest from disk.
  static FarmPackLoadResult load(String manifestPath) {
    final String contents;
    try {
      contents = File(manifestPath).readAsStringSync();
    } on FileSystemException {
      return _failure('Could not open FarmPack manifest: $manifestPath');
    }

    Object? document;
    var parseError = '';
    try {
      document = jsonDecode(contents);
    } on FormatException catch (error) {
      parseError = error.message;
    }
    if (document is! Map<String, dynamic>) {
      return _failure('FarmPack manifest is not a valid JSON object: $parseError');
    }

    final pack = FarmPack();
    final object = document;
    final error = ErrorMessage();
    final name = _readString(object, 'name', error);
    if (name == null) return _failure(error.value);
    pack.name = name;

    final defaultImage = _readString(object, 'default', error);
    if (defaultImage == null) return _failure(error.value);
    final manifestDirectory = p.dirname(p.absolute(manifestPath));
    final defaultPath = _resolveImagePath(manifestDirectory, defaultImage, 'default', error);
    if (defaultPath == null) return _failure(error.value);
    pack.defaultImagePath = defaultPath;

    final variantsValue = object['variants'];
    if (variantsValue is! List) return _failure("Manifest field 'variants' must be an array.");

    for (var index = 0; index < variantsValue.length; ++index) {
      final variantObject = variantsValue[index];
      if (variantObject is! Map<String, dynamic>) {
        return _failure('Manifest variant $index must be an object.');
      }

      final startValue = _readString(variantObject, 'start', error);
      final endValue = startValue == null ? null : _readString(variantObject, 'end', error);
      final imageValue = endValue == null ? null : _readString(variantObject, 'image', error);
      if (startValue == null || endValue == null || imageValue == null) {
        return _failure('Invalid variant $index: ${error.value}');
      }

      final variant = FarmPackVariant();
      final start = _parseMonthDay(startValue);
      final end = _parseMonthDay(endValue);
      if (start == null || end == null) {
        return _failure('Invalid date in variant $index. Use MM-DD.');
      }
      variant
        ..start = start
        ..end = end;
      final imagePath =
          _resolveImagePath(manifestDirectory, imageValue, 'variants[$index].image', error);
      if (imagePath == null) return _failure(error.value);
      variant.imagePath = imagePath;
      pack.variants.add(variant);
    }

    return FarmPackLoadResult(pack: pack);
  }
}

class FarmPackLoadResult {
  FarmPackLoadResult({FarmPack? pack, this.error = ''}) : pack = pack ?? FarmPack();

  final FarmPack pack;
  final String error;

  /// @brief Returns true when the manifest loaded without errors.
  bool get hasValue => error.isEmpty;
}

/// @brief Builds a failed load result carrying [message].
FarmPackLoadResult _failure(String message) => FarmPackLoadResult(error: message);

/// @brief Reads a required, non-empty, trimmed string field.
/// @return The value, or null after recording why the field is invalid.
String? _readString(Map<String, dynamic> object, String key, ErrorMessage error) {
  final jsonValue = object[key];
  if (jsonValue is! String || jsonValue.trim().isEmpty) {
    error.value = "Manifest field '$key' must be a non-empty string.";
    return null;
  }
  return jsonValue.trim();
}

/// @brief Parses an `MM-DD` string into a valid month/day in a leap year.
MonthDay? _parseMonthDay(String value) {
  final format = RegExp(r'^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$');
  if (!format.hasMatch(value)) return null;

  final parts = value.split('-');
  final month = int.parse(parts[0]);
  final day = int.parse(parts[1]);
  // Year 2000 is a leap year, so 02-29 is accepted, matching QDate(2000, month, day).
  final candidate = DateTime(2000, month, day);
  if (candidate.month != month || candidate.day != day) return null;
  return MonthDay(month, day);
}

/// @brief Resolves a manifest-relative image path and confines it to the pack folder.
/// @return The canonical image path, or null after recording why the path was rejected.
String? _resolveImagePath(
    String manifestDirectory, String rawPath, String field, ErrorMessage error) {
  final path = rawPath.replaceAll('\\', '/').trim();

  final segments = path.split('/');
  final hasParentSegment = segments.contains('..');
  final hasAbsolutePrefix = path.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(path);
  if (path.isEmpty || hasParentSegment || hasAbsolutePrefix) {
    error.value = "Manifest field '$field' must be a relative image path.";
    return null;
  }

  final imagePath = p.join(manifestDirectory, path);
  if (FileSystemEntity.typeSync(imagePath) != FileSystemEntityType.file) {
    error.value = 'Manifest image does not exist: $path';
    return null;
  }

  final extension = p.extension(imagePath).replaceFirst('.', '').toLowerCase();
  if (!const ['png', 'jpg', 'jpeg', 'webp'].contains(extension)) {
    error.value = 'Manifest image has an unsupported extension: $path';
    return null;
  }

  // Port note: the C++ code skipped canonicalization for Qt resource paths (":/...").
  // Flutter assets are not read through this loader, so every path is a real file.
  final canonicalRoot = Directory(manifestDirectory).resolveSymbolicLinksSync();
  final canonicalImage = File(imagePath).resolveSymbolicLinksSync();
  if (!p.isWithin(canonicalRoot, canonicalImage)) {
    error.value = 'Manifest image resolves outside the pack directory: $path';
    return null;
  }

  return canonicalImage;
}
