// Port of tests/smapi/SmapiFixture.h: builds fake SMAPI installations for tests.

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/smapi/smapi_version.dart';

/// @brief Writes a little-endian 16-bit value into a managed assembly fixture.
void put16(Uint8List data, int offset, int value) {
  data[offset] = value & 0xff;
  data[offset + 1] = (value >> 8) & 0xff;
}

/// @brief Writes a little-endian 32-bit value into a managed assembly fixture.
void put32(Uint8List data, int offset, int value) {
  put16(data, offset, value & 0xffff);
  put16(data, offset + 2, (value >> 16) & 0xffff);
}

/// @brief Writes a little-endian 64-bit value into a managed assembly fixture.
void put64(Uint8List data, int offset, int value) {
  put32(data, offset, value & 0xffffffff);
  put32(data, offset + 4, (value >> 32) & 0xffffffff);
}

/// @brief Copies a metadata name into the fixture at the requested offset.
void putName(Uint8List data, int offset, String name) {
  data.setRange(offset, offset + name.length, name.codeUnits);
}

/// @brief Builds a minimal managed assembly reporting the requested version.
Uint8List managedAssemblyFixture(int major, int minor, int patch) {
  const peOffset = 0x80;
  const optionalHeaderOffset = peOffset + 24;
  const sectionOffset = optionalHeaderOffset + 0xe0;
  const cliOffset = 0x300;
  const metadataOffset = 0x400;
  const tablesOffset = metadataOffset + 0x80;
  final data = Uint8List(0x1400);

  put16(data, 0x00, 0x5a4d);
  put32(data, 0x3c, peOffset);
  put32(data, peOffset, 0x00004550);
  put16(data, peOffset + 6, 1);
  put16(data, peOffset + 20, 0xe0);
  put16(data, optionalHeaderOffset, 0x10b);
  put32(data, optionalHeaderOffset + 92, 16);
  put32(data, optionalHeaderOffset + 96 + 14 * 8, 0x1100);
  put32(data, optionalHeaderOffset + 96 + 14 * 8 + 4, 0x48);

  putName(data, sectionOffset, '.text');
  put32(data, sectionOffset + 8, 0x1000);
  put32(data, sectionOffset + 12, 0x1000);
  put32(data, sectionOffset + 16, 0x1000);
  put32(data, sectionOffset + 20, 0x200);

  put32(data, cliOffset, 0x48);
  put32(data, cliOffset + 8, 0x1200);
  put32(data, cliOffset + 12, 0x200);

  put32(data, metadataOffset, 0x424a5342);
  put16(data, metadataOffset + 4, 1);
  put16(data, metadataOffset + 6, 1);
  put32(data, metadataOffset + 12, 8);
  putName(data, metadataOffset + 16, 'v4.0');
  put16(data, metadataOffset + 24 + 0, 0);
  put16(data, metadataOffset + 24 + 2, 2);

  const firstStream = metadataOffset + 28;
  put32(data, firstStream, 0x80);
  put32(data, firstStream + 4, 0x40);
  putName(data, firstStream + 8, '#~');
  const secondStream = metadataOffset + 40;
  put32(data, secondStream, 0xc0);
  put32(data, secondStream + 4, 1);
  putName(data, secondStream + 8, '#Strings');

  put32(data, tablesOffset, 0);
  data[tablesOffset + 4] = 2;
  data[tablesOffset + 5] = 0;
  data[tablesOffset + 6] = 0;
  data[tablesOffset + 7] = 1;
  put64(data, tablesOffset + 8, 1 << 32);
  put64(data, tablesOffset + 16, 0);
  put32(data, tablesOffset + 24, 1);
  put16(data, tablesOffset + 28 + 4, major);
  put16(data, tablesOffset + 28 + 6, minor);
  put16(data, tablesOffset + 28 + 8, patch);
  return data;
}

/// @brief Writes bytes to [path], replacing any existing file.
void writeFile(String path, List<int> data) => File(path).writeAsBytesSync(data);

/// @brief Creates an empty file at [path].
void writeEmptyFile(String path) => writeFile(path, const []);

/// @brief Marks [path] executable on POSIX systems.
void makeExecutable(String path) {
  if (!Platform.isWindows) Process.runSync('chmod', ['755', path]);
}

/// @brief Creates a complete fake SMAPI installation in [gameDirectory].
void createSmapiFixture(
    String gameDirectory, SmapiVersion coreVersion, SmapiVersion interfacesVersion,
    [String metadata = '{"Format":"4.0.0"}']) {
  Directory(p.join(gameDirectory, 'smapi-internal')).createSync(recursive: true);
  final executable =
      p.join(gameDirectory, Platform.isWindows ? 'StardewModdingAPI.exe' : 'StardewModdingAPI');
  writeEmptyFile(executable);
  makeExecutable(executable);
  writeEmptyFile(p.join(gameDirectory, 'StardewModdingAPI.dll'));
  writeEmptyFile(p.join(gameDirectory, 'StardewModdingAPI.deps.json'));
  writeEmptyFile(p.join(gameDirectory, 'StardewModdingAPI.runtimeconfig.json'));
  writeFile(p.join(gameDirectory, 'smapi-internal/metadata.json'), metadata.codeUnits);
  writeFile(p.join(gameDirectory, 'smapi-internal/SMAPI.Toolkit.dll'),
      managedAssemblyFixture(coreVersion.major, coreVersion.minor, coreVersion.patch));
  writeFile(
      p.join(gameDirectory, 'smapi-internal/SMAPI.Toolkit.CoreInterfaces.dll'),
      managedAssemblyFixture(
          interfacesVersion.major, interfacesVersion.minor, interfacesVersion.patch));
}

/// @brief Creates a temporary directory that is deleted after the current test.
Directory temporaryDirectory(void Function(void Function()) addTearDown) {
  final directory = Directory.systemTemp.createTempSync('prismatic-test-');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return Directory(directory.resolveSymbolicLinksSync());
}
