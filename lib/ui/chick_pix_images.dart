// Port of src/qt/ChickPixImages.{h,cpp}.
//
// Port notes:
// - Bundled artwork used Qt resource paths such as ":/farmpack/default.png". Those exact
//   identifiers are kept (they are stored in launcher.ini), and are mapped to Flutter assets
//   under chickens/. Flutter assets load asynchronously, so `preloadBundledImages()` must be
//   awaited once at startup (main.dart and the tests do this).
// - QImageReader/QImage became the pure-Dart `image` package; `load` returns the validated
//   encoded bytes (for Image.memory) together with the decoded pixels (for fingerprints).

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const int _maximumFileBytes = 16 * 1024 * 1024;
const int _maximumDimension = 8192;
const int _maximumPixels = 16 * 1024 * 1024;
const List<String> bundledImages = [
  ':/farmpack/default.png',
  ':/farmpack/spring.png',
  ':/farmpack/summer.png',
];

/// @brief Maps a legacy Qt resource identifier to its Flutter asset key.
String bundledAssetKey(String identifier) => 'chickens/${p.basename(identifier)}';

// Raw bytes for each bundled identifier, filled by preloadBundledImages().
final Map<String, Uint8List> _bundledBytes = {};
// Resource pixels never change during the process; keep only their small digests.
// Custom files deliberately bypass this cache so edits and deletions remain visible.
final Map<String, String> _bundledFingerprints = {};

/// @brief A validated, decoded image plus the original bytes for display.
class ChickPixImage {
  ChickPixImage(this.bytes, this.pixels);

  final Uint8List bytes;
  final img.Image pixels;
}

/// @brief Identifies decoded pixels and dimensions independently of filenames and encoded
/// metadata.
String _imageFingerprint(img.Image image) {
  final normalized = image.convert(numChannels: 4);
  final header = '${normalized.width}x${normalized.height}'.codeUnits;
  final pixels = normalized.getBytes(order: img.ChannelOrder.argb);
  return sha256.convert([...header, ...pixels]).toString();
}

class ChickPixImages {
  /// @brief Uses custom roots beside the config file and beside the executable.
  ChickPixImages(String configFile)
      : _folders = {
          p.join(p.dirname(p.absolute(configFile)), 'chickens'),
          p.join(p.dirname(Platform.resolvedExecutable), 'chickens'),
        }.toList();

  final List<String> _folders;

  /// @brief Loads bundled artwork bytes from Flutter assets; call once before other methods.
  static Future<void> preloadBundledImages() async {
    for (final identifier in bundledImages) {
      if (_bundledBytes.containsKey(identifier)) continue;
      final data = await rootBundle.load(bundledAssetKey(identifier));
      _bundledBytes[identifier] = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
  }

  /// @brief Returns the absolute custom folders, independent of the working directory.
  List<String> folders() => List.of(_folders);

  /// @brief Resolves a bundled identifier or custom path confined to its allowed folder.
  String _allowedPath(String selection) {
    if (bundledImages.contains(selection)) return selection;
    if (!p.isAbsolute(selection)) return '';
    if (FileSystemEntity.typeSync(selection) != FileSystemEntityType.file) return '';
    final String canonicalFile;
    try {
      canonicalFile = File(selection).resolveSymbolicLinksSync();
    } on FileSystemException {
      return '';
    }
    for (final folder in _folders) {
      final String canonicalFolder;
      try {
        canonicalFolder = Directory(folder).resolveSymbolicLinksSync();
      } on FileSystemException {
        continue;
      }
      // Only direct children are offered by the catalog; resolve links before checking
      // containment.
      if (p.dirname(p.normalize(selection)) != p.normalize(folder)) continue;
      if (p.isWithin(canonicalFolder, canonicalFile)) return canonicalFile;
    }
    return '';
  }

  /// @brief Decodes an allowed image.
  /// @return The image, or null for invalid, oversized, or unavailable selections.
  ChickPixImage? load(String selection) {
    final path = _allowedPath(selection);
    if (path.isEmpty) return null;
    final extension = p.extension(selection).replaceFirst('.', '').toLowerCase();
    if (!const ['png', 'jpg', 'jpeg', 'webp'].contains(extension)) return null;

    final Uint8List bytes;
    if (bundledImages.contains(path)) {
      final bundled = _bundledBytes[path];
      if (bundled == null) return null;
      bytes = bundled;
    } else {
      final file = File(path);
      final size = file.lengthSync();
      if (size <= 0 || size > _maximumFileBytes) return null;
      try {
        bytes = file.readAsBytesSync();
      } on FileSystemException {
        return null;
      }
    }

    // Check dimensions from the header before decoding pixels, like QImageReader::size().
    final decoder = img.findDecoderForData(bytes);
    if (decoder is! img.PngDecoder && decoder is! img.JpegDecoder && decoder is! img.WebPDecoder) {
      return null;
    }
    final info = decoder!.startDecode(bytes);
    if (info == null) return null;
    final pixels = info.width * info.height;
    if (info.width <= 0 ||
        info.height <= 0 ||
        info.width > _maximumDimension ||
        info.height > _maximumDimension ||
        pixels > _maximumPixels) {
      return null;
    }
    final image = decoder.decode(bytes);
    if (image == null) return null;
    return ChickPixImage(bytes, image);
  }

  /// @brief Returns valid images with unique pixels and filenames, preferring bundled
  /// entries.
  List<String> catalog() {
    final candidates = List.of(bundledImages);
    for (final folder in _folders) {
      final directory = Directory(folder);
      if (!directory.existsSync()) continue;
      final files = directory
          .listSync()
          .where((entry) => FileSystemEntity.typeSync(entry.path) == FileSystemEntityType.file)
          .map((entry) => p.absolute(entry.path))
          .toList()
        ..sort();
      candidates.addAll(files);
    }
    final images = <String>[];
    final filenames = <String>{};
    final fingerprints = <String>{};
    for (final path in candidates) {
      final filename = p.basename(path).toLowerCase();
      if (filenames.contains(filename)) continue;
      final imageKey = _fingerprint(path);
      if (imageKey.isEmpty || fingerprints.contains(imageKey)) continue;
      images.add(path);
      filenames.add(filename);
      fingerprints.add(imageKey);
    }
    return images;
  }

  /// @brief Maps legacy empty values and duplicate choices to catalog entries; keeps
  /// unmatched paths.
  String resolveSelection(String selection, List<String> catalog) {
    if (selection.isEmpty) return defaultImage();
    if (catalog.contains(selection)) return selection;
    final selectedFingerprint = _fingerprint(selection);
    if (selectedFingerprint.isNotEmpty) {
      for (final path in catalog) {
        if (_fingerprint(path) == selectedFingerprint) return path;
      }
    }
    final selectedName = p.basename(selection).toLowerCase();
    for (final path in catalog) {
      if (p.basename(path).toLowerCase() == selectedName) return path;
    }
    return selection;
  }

  /// @brief Returns the bundled Default artwork identifier used for new or unavailable
  /// selections.
  static String defaultImage() => bundledImages.first;

  /// @brief Reuses immutable bundled fingerprints and freshly validates custom image pixels.
  String _fingerprint(String selection) {
    if (!bundledImages.contains(selection)) {
      final image = load(selection);
      return image == null ? '' : _imageFingerprint(image.pixels);
    }
    return _bundledFingerprints.putIfAbsent(selection, () {
      final image = load(selection);
      return image == null ? '' : _imageFingerprint(image.pixels);
    });
  }
}
