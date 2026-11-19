// Port of src/smapi/ManagedAssemblyVersionReader.{h,cpp}.
//
// Reads the assembly version from a .NET (CLR) DLL without loading or executing it. The
// parser walks: DOS header -> PE header -> CLR data directory -> metadata root -> "#~"
// table stream -> Assembly table row. Every read is bounds-checked because SMAPI files on
// disk are untrusted input.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../common/error_message.dart';
import 'smapi_version.dart';

const int _kMaximumAssemblySize = 64 * 1024 * 1024;
const int _kMaximumMetadataTable = 44;

// Port note: the C++ helpers return bool and write through a pointer. These Dart helpers
// return the value, or null when the read would run past the end of the data.

/// @brief Reads a little-endian 16-bit value, or returns null when out of range.
int? _readU16(Uint8List data, int offset) {
  if (offset < 0 || offset > data.length - 2) return null;
  return data[offset] | (data[offset + 1] << 8);
}

/// @brief Reads a little-endian 32-bit value, or returns null when out of range.
int? _readU32(Uint8List data, int offset) {
  if (offset < 0 || offset > data.length - 4) return null;
  return data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}

/// @brief Reads a little-endian 64-bit value, or returns null when out of range.
int? _readU64(Uint8List data, int offset) {
  final lower = _readU32(data, offset);
  final upper = _readU32(data, offset + 4);
  if (lower == null || upper == null) return null;
  // Dart ints are 64-bit signed; the "valid tables" bitmask only uses the low 45 bits.
  return lower | (upper << 32);
}

/// @brief Rounds up to the next multiple of four, as metadata headers require.
int _align4(int value) => (value + 3) & ~3;

/// @brief Returns true when [offset, offset + size) lies completely inside the data.
bool _hasRange(Uint8List data, int offset, int size) =>
    offset >= 0 && size >= 0 && offset <= data.length && size <= data.length - offset;

/// @brief Maps a relative virtual address to a file offset using the PE section table.
int? _mapRva(Uint8List data, int rva, int sectionOffset, int sectionCount) {
  for (var index = 0; index < sectionCount; ++index) {
    final current = sectionOffset + index * 40;
    final virtualSize = _readU32(data, current + 8);
    final virtualAddress = _readU32(data, current + 12);
    final rawSize = _readU32(data, current + 16);
    final rawAddress = _readU32(data, current + 20);
    if (virtualSize == null || virtualAddress == null || rawSize == null || rawAddress == null) {
      return null;
    }

    final mappedSize = math.max(virtualSize, rawSize);
    if (rva < virtualAddress || rva - virtualAddress >= mappedSize) continue;
    final fileOffset = rawAddress + (rva - virtualAddress);
    if (!_hasRange(data, fileOffset, 1)) return null;
    return fileOffset;
  }
  return null;
}

class _StreamInfo {
  const _StreamInfo(this.offset, this.size);
  final int offset;
  final int size;
}

/// @brief Finds a named metadata stream header such as "#~".
_StreamInfo? _readStreamInfo(Uint8List data, int metadataOffset, int metadataSize,
    String wantedName, ErrorMessage? errorMessage) {
  final versionLength = _readU32(data, metadataOffset + 12);
  if (versionLength == null) {
    setError(errorMessage, 'SMAPI metadata has no version header.');
    return null;
  }

  final streamHeaderStart = _align4(metadataOffset + 16 + versionLength);
  final streamCount =
      _hasRange(data, metadataOffset, metadataSize) ? _readU16(data, streamHeaderStart + 2) : null;
  if (streamCount == null) {
    setError(errorMessage, 'SMAPI metadata has an invalid stream header.');
    return null;
  }

  var cursor = streamHeaderStart + 4;
  for (var index = 0; index < streamCount; ++index) {
    final offset = _readU32(data, cursor);
    final size = _readU32(data, cursor + 4);
    if (offset == null || size == null) {
      setError(errorMessage, 'SMAPI metadata contains a truncated stream header.');
      return null;
    }

    final nameStart = cursor + 8;
    final nameEnd = nameStart < data.length ? data.indexOf(0, nameStart) : -1;
    if (nameEnd < 0 || nameEnd >= metadataOffset + metadataSize) {
      setError(errorMessage, 'SMAPI metadata contains an invalid stream name.');
      return null;
    }

    final name = String.fromCharCodes(data.sublist(nameStart, nameEnd));
    if (name == wantedName) {
      final streamEnd = offset + size;
      if (streamEnd > metadataSize) {
        setError(errorMessage, 'SMAPI metadata stream exceeds its declared size.');
        return null;
      }
      return _StreamInfo(offset, size);
    }

    cursor = _align4(nameEnd + 1);
  }

  setError(errorMessage, 'SMAPI assembly is missing a required metadata stream.');
  return null;
}

/// @brief Row counts and heap-size flags needed to compute metadata row widths.
class _TableContext {
  final List<int> rows = List<int>.filled(_kMaximumMetadataTable + 1, 0);
  int heapSizes = 0;

  int get stringIndexSize => (heapSizes & 1) != 0 ? 4 : 2;
  int get guidIndexSize => (heapSizes & 2) != 0 ? 4 : 2;
  int get blobIndexSize => (heapSizes & 4) != 0 ? 4 : 2;

  int tableIndexSize(int table) => rows[table] < 65536 ? 2 : 4;

  int codedIndexSize(int tagBits, List<int> tables) {
    var maximumRows = 0;
    for (final table in tables) {
      maximumRows = math.max(maximumRows, rows[table]);
    }
    return maximumRows < (1 << (16 - tagBits)) ? 2 : 4;
  }
}

/// @brief Returns the byte width of one row in a metadata table (ECMA-335 II.22).
int? _tableRowSize(_TableContext context, int table) {
  final s = context.stringIndexSize;
  final g = context.guidIndexSize;
  final b = context.blobIndexSize;
  final field = context.tableIndexSize(4);
  final method = context.tableIndexSize(6);
  final param = context.tableIndexSize(8);
  final event = context.tableIndexSize(20);
  final property = context.tableIndexSize(23);

  switch (table) {
    case 0:
      return 2 + s + 3 * g;
    case 1:
      return context.codedIndexSize(2, [0, 26, 35, 1]) + 2 * s;
    case 2:
      return 4 + 2 * s + context.codedIndexSize(2, [2, 1, 27]) + field + method;
    case 3:
      return field;
    case 4:
      return 2 + s + b;
    case 5:
      return method;
    case 6:
      return 8 + s + b + param;
    case 7:
      return param;
    case 8:
      return 4 + s;
    case 9:
      return context.tableIndexSize(2) + context.codedIndexSize(2, [2, 1, 27]);
    case 10:
      return context.codedIndexSize(3, [2, 1, 26, 6, 27]) + s + b;
    case 11:
      return 2 + context.codedIndexSize(2, [4, 8, 23]) + b;
    case 12:
      return context.codedIndexSize(5, [
            6, 4, 1, 2, 8, 9, 10, 0, 23, 20, 17, //
            26, 27, 32, 35, 38, 39, 40, 42, 44, 43,
          ]) +
          context.codedIndexSize(3, [6, 10]) +
          b;
    case 13:
      return context.codedIndexSize(1, [4, 8]) + b;
    case 14:
      return 2 + context.codedIndexSize(2, [2, 6, 32]) + b;
    case 15:
      return 6 + context.tableIndexSize(2);
    case 16:
      return 4 + field;
    case 17:
      return b;
    case 18:
      return context.tableIndexSize(2) + event;
    case 19:
      return event;
    case 20:
      return 2 + s + context.codedIndexSize(2, [2, 1, 27]);
    case 21:
      return context.tableIndexSize(2) + property;
    case 22:
      return property;
    case 23:
      return 2 + s + b;
    case 24:
      return 2 + method + context.codedIndexSize(1, [20, 23]);
    case 25:
      return context.tableIndexSize(2) + context.codedIndexSize(1, [6, 10]) * 2;
    case 26:
      return s;
    case 27:
      return b;
    case 28:
      return 2 + context.codedIndexSize(1, [4, 6]) + s + context.tableIndexSize(26);
    case 29:
      return 4 + field;
    case 30:
      return 8;
    case 31:
      return 4;
    default:
      return null;
  }
}

/// @brief Reads the version stored in the metadata Assembly table (table 0x20).
SmapiVersion? _readMetadataVersion(
    Uint8List data, int metadataOffset, int metadataSize, ErrorMessage? errorMessage) {
  final signature = _readU32(data, metadataOffset);
  if (signature == null || signature != 0x424A5342) {
    setError(errorMessage, 'SMAPI assembly has invalid CLR metadata.');
    return null;
  }

  // Prefer the optimized "#~" stream, then fall back to the uncompressed "#-" stream.
  final optimizedTablesError = ErrorMessage();
  var tables = _readStreamInfo(data, metadataOffset, metadataSize, '#~', optimizedTablesError);
  tables ??= _readStreamInfo(data, metadataOffset, metadataSize, '#-', errorMessage);
  if (tables == null) return null;

  final tablesOffset = metadataOffset + tables.offset;
  if (!_hasRange(data, tablesOffset, tables.size)) {
    setError(errorMessage, 'SMAPI assembly has invalid metadata table bounds.');
    return null;
  }
  final tablesEnd = tablesOffset + tables.size;
  final tableHeader = _readU16(data, tablesOffset + 4);
  final valid = _readU64(data, tablesOffset + 8);
  if (tableHeader == null || valid == null) {
    setError(errorMessage, 'SMAPI assembly has a truncated metadata table stream.');
    return null;
  }
  final heapSizes = (tableHeader >> 8) & 0xff;

  final context = _TableContext()..heapSizes = heapSizes;
  var rowCountOffset = tablesOffset + 24;
  for (var table = 0; table <= _kMaximumMetadataTable; ++table) {
    if ((valid & (1 << table)) != 0) {
      final rows = rowCountOffset > tablesEnd - 4 ? null : _readU32(data, rowCountOffset);
      if (rows == null) {
        setError(errorMessage, 'SMAPI assembly has truncated metadata row counts.');
        return null;
      }
      context.rows[table] = rows;
      rowCountOffset += 4;
    }
  }

  if (context.rows[32] == 0) {
    setError(errorMessage, 'SMAPI assembly has no Assembly metadata row.');
    return null;
  }

  // Skip every table that precedes the Assembly table to find its first row.
  var assemblyOffset = rowCountOffset;
  for (var table = 0; table < 32; ++table) {
    final rowSize = _tableRowSize(context, table);
    if (rowSize == null) {
      setError(errorMessage, 'SMAPI assembly uses an unsupported metadata table.');
      return null;
    }
    final tableSize = rowSize * context.rows[table];
    // Dart ints are 64-bit, so this mirrors the C++ qsizetype overflow guard.
    if (tableSize > (1 << 62) - assemblyOffset) {
      setError(errorMessage, 'SMAPI assembly metadata is too large.');
      return null;
    }
    assemblyOffset += tableSize;
    if (assemblyOffset > tablesEnd) {
      setError(errorMessage, 'SMAPI assembly metadata table exceeds its declared size.');
      return null;
    }
  }

  if (assemblyOffset > tablesEnd - 12) {
    setError(errorMessage, 'SMAPI assembly has a truncated Assembly metadata row.');
    return null;
  }

  // Assembly row layout: HashAlgId (u32), MajorVersion, MinorVersion, BuildNumber (u16 each).
  final hashAlgorithm = _readU32(data, assemblyOffset);
  final major = _readU16(data, assemblyOffset + 4);
  final minor = _readU16(data, assemblyOffset + 6);
  final patch = _readU16(data, assemblyOffset + 8);
  if (hashAlgorithm == null || major == null || minor == null || patch == null) {
    setError(errorMessage, 'SMAPI assembly has a truncated Assembly metadata row.');
    return null;
  }

  return SmapiVersion(major: major, minor: minor, patch: patch);
}

/// @brief Reads assembly versions from SMAPI's managed DLLs without executing them.
class ManagedAssemblyVersionReader {
  const ManagedAssemblyVersionReader();

  /// @brief Parses the CLR metadata of [filePath] and returns its assembly version.
  /// @return The version, or null when the file is missing, oversized, or not a valid
  /// managed assembly; [errorMessage] then receives the reason.
  SmapiVersion? read(String filePath, [ErrorMessage? errorMessage]) {
    final file = File(filePath);
    if (FileSystemEntity.typeSync(filePath) != FileSystemEntityType.file) {
      setError(errorMessage, 'SMAPI assembly file is missing.');
      return null;
    }
    final fileSize = file.lengthSync();
    if (fileSize <= 0 || fileSize > _kMaximumAssemblySize) {
      setError(errorMessage, 'SMAPI assembly file has an invalid size.');
      return null;
    }

    final Uint8List data;
    try {
      data = file.readAsBytesSync();
    } on FileSystemException {
      setError(errorMessage, 'SMAPI assembly file could not be read.');
      return null;
    }
    if (data.length != fileSize) {
      setError(errorMessage, 'SMAPI assembly file could not be read completely.');
      return null;
    }

    final dosSignature = _readU16(data, 0);
    final peOffset = _readU32(data, 0x3C);
    if (dosSignature != 0x5A4D || peOffset == null || !_hasRange(data, peOffset, 4)) {
      setError(errorMessage, 'SMAPI assembly is not a valid PE file.');
      return null;
    }

    final peSignature = _readU32(data, peOffset);
    final sectionCount = _readU16(data, peOffset + 6);
    final optionalHeaderSize = _readU16(data, peOffset + 20);
    if (peSignature != 0x00004550 || sectionCount == null || optionalHeaderSize == null) {
      setError(errorMessage, 'SMAPI assembly has an invalid PE header.');
      return null;
    }

    final optionalHeaderOffset = peOffset + 24;
    final optionalHeaderMagic = _readU16(data, optionalHeaderOffset);
    if (optionalHeaderMagic == null) {
      setError(errorMessage, 'SMAPI assembly has no optional PE header.');
      return null;
    }
    final pe32Plus = optionalHeaderMagic == 0x20B;
    if (optionalHeaderMagic != 0x10B && !pe32Plus) {
      setError(errorMessage, 'SMAPI assembly uses an unsupported PE format.');
      return null;
    }

    // Data directory 14 is the CLR runtime header.
    final dataDirectoryOffset = optionalHeaderOffset + (pe32Plus ? 112 : 96);
    final directoryCount = _readU32(data, optionalHeaderOffset + (pe32Plus ? 108 : 92));
    final clrRva = (directoryCount != null && directoryCount > 14)
        ? _readU32(data, dataDirectoryOffset + 14 * 8)
        : null;
    if (clrRva == null) {
      setError(errorMessage, 'SMAPI assembly has no CLR metadata directory.');
      return null;
    }

    final sectionOffset = optionalHeaderOffset + optionalHeaderSize;
    final cliOffset = _mapRva(data, clrRva, sectionOffset, sectionCount);
    if (cliOffset == null) {
      setError(errorMessage, 'SMAPI assembly has an invalid CLR metadata location.');
      return null;
    }

    final metadataRva = _readU32(data, cliOffset + 8);
    final metadataSize = _readU32(data, cliOffset + 12);
    if (metadataRva == null || metadataSize == null) {
      setError(errorMessage, 'SMAPI assembly has an invalid CLR header.');
      return null;
    }

    final metadataOffset = _mapRva(data, metadataRva, sectionOffset, sectionCount);
    if (metadataOffset == null || !_hasRange(data, metadataOffset, metadataSize)) {
      setError(errorMessage, 'SMAPI assembly has invalid CLR metadata bounds.');
      return null;
    }
    return _readMetadataVersion(data, metadataOffset, metadataSize, errorMessage);
  }
}
