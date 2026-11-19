// Port of tests/mods/ModInstallerTests.cpp.
//
// Port note: archives are built with the `archive` package's ZipEncoder instead of
// libarchive. The C++ "7zip" row now checks that 7z archives are rejected with guidance,
// because the Flutter build only reads ZIP files.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/mods/mod_installer.dart';

import '../smapi/smapi_fixture.dart' show temporaryDirectory;

/// @brief Writes [data] to [path], creating parent folders.
void writeFile(String path, Object data) {
  Directory(p.dirname(path)).createSync(recursive: true);
  if (data is String) {
    File(path).writeAsStringSync(data);
  } else {
    File(path).writeAsBytesSync(data as List<int>);
  }
}

/// @brief Creates a valid code mod (or content pack) with an asset file.
void makeMod(String path, {String id = 'Test.Mod', bool pack = false}) {
  final manifest = <String, Object>{
    'Name': 'Test mod',
    'Author': 'Test',
    'Version': '1.0.0',
    'Description': 'Fixture',
    'UniqueID': id,
    if (pack)
      'ContentPackFor': {'UniqueID': 'Pathoschild.ContentPatcher'}
    else
      'EntryDll': 'Test.dll',
  };
  writeFile('$path/manifest.json', const JsonEncoder.withIndent('    ').convert(manifest));
  writeFile(pack ? '$path/content.json' : '$path/Test.dll', 'fixture');
  writeFile('$path/assets/sprite.png', 'asset bytes');
}

String manifestText(String directory) => File('$directory/manifest.json').readAsStringSync();

/// @brief Writes a ZIP archive containing [files], plus an optional symbolic link entry.
void makeArchive(String path, List<(String, String)> files, {String link = ''}) {
  final archive = Archive();
  for (final (name, data) in files) {
    archive.addFile(ArchiveFile.string(name, data));
  }
  if (link.isNotEmpty) archive.addFile(ArchiveFile.symlink('Mod/link', link));
  File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

/// @brief Creates a minimal game folder whose path contains spaces.
String makeGame(String temp) {
  final game = p.join(temp, 'Game with spaces');
  writeFile('$game/StardewValley.dll', 'fixture');
  return game;
}

bool exists(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

void main() {
  late String temp;
  late String game;
  setUp(() {
    temp = temporaryDirectory(addTearDown).path;
    game = makeGame(temp);
  });
  String path(String name) => p.join(temp, name);

  test('bundledSmapiManifestDoesNotBlockInstallation', () {
    final console = '$game/Mods/ConsoleCommands';
    const manifest = '''{
            "Name": "Console Commands",
            "Author": "SMAPI",
            "Version": "4.5.2",
            "Description": "Adds SMAPI console commands that let you manipulate the game.",
            "UniqueId": "SMAPI.ConsoleCommands",
            "EntryDll": "ConsoleCommands.dll",
            "MinimumApiVersion": "4.5.2"
        }''';
    writeFile('$console/manifest.json', manifest);
    writeFile('$console/ConsoleCommands.dll', 'fixture');
    final listing = ModInstaller.installed(game);
    expect(listing.succeeded, isTrue, reason: listing.error);
    expect(listing.mods.single.uniqueId, 'SMAPI.ConsoleCommands');

    makeMod(path('NewMod'));
    final result = ModInstaller.install([path('NewMod')], game);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(exists('$game/Mods/NewMod/Test.dll'), isTrue);
    expect(manifestText(console), manifest);

    makeMod(path('Duplicate'), id: 'SMAPI.ConsoleCommands');
    final duplicate = ModInstaller.install([path('Duplicate')], game);
    expect(duplicate.succeeded, isFalse);
    expect(duplicate.error, contains('already installed'));
    expect(exists('$game/Mods/Duplicate'), isFalse);
  });

  for (final pack in [false, true]) {
    test('manifestFieldNamesAreCaseInsensitive (${pack ? 'content-pack' : 'code-mod'})', () {
      final source = path('MixedCase');
      makeMod(source, id: 'Test.MixedCase', pack: pack);
      final original = jsonDecode(manifestText(source)) as Map<String, dynamic>;
      final lowercase = {
        for (final entry in original.entries) entry.key.toLowerCase(): entry.value
      };
      if (pack) lowercase['contentpackfor'] = {'uniqueId': 'Pathoschild.ContentPatcher'};
      writeFile('$source/manifest.json', jsonEncode(lowercase));
      final result = ModInstaller.install([source], game);
      expect(result.succeeded, isTrue, reason: result.error);
      expect(result.mods.single.uniqueId, 'Test.MixedCase');
      final listing = ModInstaller.installed(game);
      expect(listing.succeeded, isTrue, reason: listing.error);
      expect(listing.mods.first.uniqueId, 'Test.MixedCase');
    });
  }

  test('installsCompleteFolderAndListsFromDisk', () {
    final source = path('download/MyMod');
    makeMod(source);
    final result = ModInstaller.install([source], game);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.mods, hasLength(1));
    expect(exists('$game/Mods/MyMod/assets/sprite.png'), isTrue);
    expect(exists('$source/Test.dll'), isTrue);
    final listing = ModInstaller.installed(game);
    expect(listing.succeeded, isTrue, reason: listing.error);
    expect(listing.mods.single.uniqueId, 'Test.Mod');
  });

  test('findsModsInsideDownloadWrappers', () {
    final source = path('download-123-456/Mods');
    makeMod('$source/Code', id: 'Test.Code');
    makeMod('$source/[CP] Pack', id: 'Test.Pack', pack: true);
    writeFile('$source/README.txt', 'ignored wrapper documentation');
    final result = ModInstaller.install([p.dirname(source)], game);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.mods, hasLength(2));
    expect(exists('$game/Mods/[CP] Pack/content.json'), isTrue);
    expect(exists('$game/Mods/README.txt'), isFalse);
  });

  test('individualFileResolvesItsModFolder', () {
    final source = path('download/Pack');
    makeMod(source, id: 'Test.Pack', pack: true);
    final result = ModInstaller.install(['$source/assets/sprite.png'], game);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(exists('$game/Mods/Pack/manifest.json'), isTrue);
    expect(exists('$game/Mods/Pack/content.json'), isTrue);
  });

  test('repeatedFilesFromOneModAreDeduplicated', () {
    final source = path('download/Mod');
    makeMod(source);
    final result = ModInstaller.install(['$source/manifest.json', '$source/Test.dll'], game);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.mods, hasLength(1));
  });

  test('rejectsDuplicateIdentityInDifferentFolderWithoutOverwriting', () {
    makeMod('$game/Mods/Group/AlreadyInstalled');
    final source = path('download/DifferentName');
    makeMod(source);
    final result = ModInstaller.install([source], game);
    expect(result.succeeded, isFalse);
    expect(result.error, contains('Test.Mod'));
    expect(exists('$game/Mods/DifferentName'), isFalse);
    expect(exists('$game/Mods/Group/AlreadyInstalled/Test.dll'), isTrue);
  });

  test('validatesWholeBatchBeforeInstalling', () {
    makeMod(path('Good'));
    writeFile(path('loose.xnb'), 'not a SMAPI package');
    final result = ModInstaller.install([path('Good'), path('loose.xnb')], game);
    expect(result.succeeded, isFalse);
    expect(exists('$game/Mods/Good'), isFalse);
  });

  test('rejectsMissingEntryDll', () {
    makeMod(path('Broken'));
    File(path('Broken/Test.dll')).deleteSync();
    expect(ModInstaller.install([path('Broken')], game).succeeded, isFalse);
    expect(exists('$game/Mods/Broken'), isFalse);
  });

  test('rejectsInvalidGame', () {
    makeMod(path('Mod'));
    final otherTemp = temporaryDirectory(addTearDown).path;
    expect(ModInstaller.install([path('Mod')], otherTemp).succeeded, isFalse);
    expect(exists(p.join(otherTemp, 'Mods')), isFalse);
  });

  for (final (row, prefix) in [
    ('nexus-zip', 'download-123/Mod/'),
    ('root-manifest', ''),
    ('windows-separators', r'download\Mod\'),
  ]) {
    test('installsArchives ($row)', () {
      makeMod(path('Fixture'));
      final archive = path('Nexus-123-1-0.zip');
      makeArchive(archive, [
        ('${prefix}manifest.json', manifestText(path('Fixture'))),
        ('${prefix}Test.dll', 'DLL'),
        ('${prefix}assets/sprite.png', 'sprite'),
      ]);
      final result = ModInstaller.install([archive], game);
      expect(result.succeeded, isTrue, reason: result.error);
      expect(result.mods, hasLength(1));
      final folder = prefix.isEmpty ? 'Test.Mod' : 'Mod';
      expect(exists('$game/Mods/$folder/assets/sprite.png'), isTrue);
      expect(exists(archive), isTrue);
    });
  }

  test('rejects7zArchivesWithGuidance (was installsArchives 7zip)', () {
    writeFile(path('Mod.7z'), 'not read');
    final result = ModInstaller.install([path('Mod.7z')], game);
    expect(result.succeeded, isFalse);
    expect(result.error, contains('Extract the archive'));
  });

  for (final (row, entry) in [
    ('traversal', '../outside.txt'),
    ('absolute', '/tmp/outside.txt'),
    ('drive', 'C:/outside.txt'),
    ('backslash-traversal', r'Mod\..\..\outside.txt'),
    ('windows-device', 'Mod/CON.txt'),
    ('alternate-stream', 'Mod/file:stream'),
  ]) {
    test('rejectsUnsafeArchiveEntries ($row)', () {
      makeMod(path('Fixture'));
      makeArchive(path('bad.zip'), [
        ('Mod/manifest.json', manifestText(path('Fixture'))),
        ('Mod/Test.dll', 'fixture'),
        (entry, 'malicious'),
      ]);
      expect(ModInstaller.install([path('bad.zip')], game).succeeded, isFalse);
      expect(exists('$game/Mods/Mod'), isFalse);
      expect(exists(path('outside.txt')), isFalse);
    });
  }

  test('rejectsArchiveLinksAndCaseCollisions', () {
    makeMod(path('Fixture'));
    final files = [
      ('Mod/manifest.json', manifestText(path('Fixture'))),
      ('Mod/Test.dll', 'fixture'),
    ];
    makeArchive(path('link.zip'), files, link: temp);
    expect(ModInstaller.install([path('link.zip')], game).succeeded, isFalse);
    makeArchive(path('case.zip'), [...files, ('Mod/TEST.dll', 'collision')]);
    expect(ModInstaller.install([path('case.zip')], game).succeeded, isFalse);
    expect(exists('$game/Mods/Mod'), isFalse);
  });

  test('rejectsCorruptArchive', () {
    writeFile(path('corrupt.zip'), 'not an archive');
    expect(ModInstaller.install([path('corrupt.zip')], game).succeeded, isFalse);
  });

  test('rejectsLinkedSourceAndDestination', () {
    makeMod(path('Mod'));
    Link(path('Mod/linked.dll')).createSync(path('Mod/Test.dll'));
    expect(ModInstaller.install([path('Mod')], game).succeeded, isFalse);
    Link(path('Mod/linked.dll')).deleteSync();
    Directory(path('Elsewhere')).createSync();
    Link('$game/Mods').createSync(path('Elsewhere'));
    expect(ModInstaller.install([path('Mod')], game).succeeded, isFalse);
    expect(Directory(path('Elsewhere')).listSync(), isEmpty);
  }, skip: Platform.isWindows);

  test('resolvesMacBundleRoot', () {
    final bundle = path('Stardew Valley.app');
    writeFile('$bundle/Contents/MacOS/StardewValley.dll', 'fixture');
    makeMod(path('Mod'));
    final result = ModInstaller.install([path('Mod')], bundle);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(exists('$bundle/Contents/MacOS/Mods/Mod/manifest.json'), isTrue);
  });

  test('rejectsCollidingFoldersAndBatchIdentities', () {
    makeMod('$game/Mods/Cozy', id: 'Existing.Cozy');
    makeMod(path('download/cozy'), id: 'New.Cozy');
    expect(ModInstaller.install([path('download/cozy')], game).succeeded, isFalse);
    makeMod(path('First'), id: 'Same.Identity');
    makeMod(path('Second'), id: 'Same.Identity');
    expect(ModInstaller.install([path('First'), path('Second')], game).succeeded, isFalse);
    expect(exists('$game/Mods/First'), isFalse);
    expect(exists('$game/Mods/Second'), isFalse);
  });

  test('rejectsOversizedFilesAndDeepFolders', () {
    makeMod(path('Big'));
    // A sparse file: the size is checked before any bytes are copied.
    File(path('Big/large.bin')).openSync(mode: FileMode.write)
      ..truncateSync(513 * 1024 * 1024)
      ..closeSync();
    final oversized = ModInstaller.install([path('Big')], game);
    expect(oversized.succeeded, isFalse);
    expect(oversized.error, contains('512 MiB'));

    var deep = path('Deep');
    for (var i = 0; i < 66; ++i) {
      deep += '/d';
    }
    makeMod(deep);
    final nested = ModInstaller.install([path('Deep')], game);
    expect(nested.succeeded, isFalse);
    expect(nested.error, contains('64-level'));
    expect(exists('$game/Mods/Big'), isFalse);
    expect(exists('$game/Mods/Mod'), isFalse);
    final leftovers = Directory(game)
        .listSync()
        .where((entry) => p.basename(entry.path).startsWith('.prismatic-install-'));
    expect(leftovers, isEmpty);
  });

  test('rejectsMalformedManifestAndAcceptsComments', () {
    makeMod(path('Bad'));
    writeFile(path('Bad/manifest.json'), '{broken json}');
    expect(ModInstaller.install([path('Bad')], game).succeeded, isFalse);
    makeMod(path('Commented'));
    final original = manifestText(path('Commented'));
    writeFile(path('Commented/manifest.json'), '// Mod author comment\n$original');
    final result = ModInstaller.install([path('Commented')], game);
    expect(result.succeeded, isTrue, reason: result.error);
  });

  test('rejectsExcessiveManifestNesting', () {
    makeMod(path('DeepJson'));
    var data = manifestText(path('DeepJson'));
    final end = data.lastIndexOf('}');
    data = '${data.substring(0, end)},"Extra":${'[' * 80}0${']' * 80}${data.substring(end)}';
    writeFile(path('DeepJson/manifest.json'), data);
    final result = ModInstaller.install([path('DeepJson')], game);
    expect(result.succeeded, isFalse);
    expect(result.error, contains('nesting'));
  });

  test('acceptsSmapiStyleTrailingCommasWithoutChangingStrings', () {
    makeMod(path('RelaxedJson'));
    writeFile(
        path('RelaxedJson/manifest.json'),
        '{"Name":"Literal ,} and ,] strings", "Author":"Test", "Version":"1.0.0",'
        '"Description":"https://example.com/a//b", "UniqueID":"Test.Relaxed",'
        '"EntryDll":"Test.dll", "UpdateKeys":["Nexus:123", /* comment */],}');
    final result = ModInstaller.install([path('RelaxedJson')], game);
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.mods.first.name, 'Literal ,} and ,] strings');
  });
}
