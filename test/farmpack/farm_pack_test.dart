// Port of tests/farmpack/FarmPackTests.cpp.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/farmpack/farm_pack.dart';

import '../smapi/smapi_fixture.dart' show temporaryDirectory;

void main() {
  late String directory;
  setUp(() => directory = temporaryDirectory(addTearDown).path);

  String writeManifest(String contents) {
    final manifestPath = p.join(directory, 'manifest.json');
    File(manifestPath).writeAsStringSync(contents);
    return manifestPath;
  }

  void touch(String name) => File(p.join(directory, name)).writeAsBytesSync(const []);
  String path(String name) => p.join(directory, name);

  test('loadsManifestAndResolvesPaths', () {
    touch('default.png');
    final result =
        FarmPack.load(writeManifest('{"name":"ChickPix","default":"default.png","variants":[]}'));

    expect(result.hasValue, isTrue, reason: result.error);
    expect(result.pack.name, 'ChickPix');
    expect(result.pack.defaultImagePath, path('default.png'));
    expect(result.pack.imageForDate(DateTime(2026, 1, 1)), path('default.png'));
  });

  test('selectsFirstMatchingSeasonalVariant', () {
    touch('default.png');
    touch('spring.png');
    touch('spring-priority.png');
    final result = FarmPack.load(writeManifest(
        '{"name":"ChickPix","default":"default.png","variants":[{"start":"03-01","end":"05-31","image":"spring.png"},{"start":"04-01","end":"04-30","image":"spring-priority.png"}]}'));

    expect(result.hasValue, isTrue, reason: result.error);
    expect(result.pack.imageForDate(DateTime(2026, 4, 15)), path('spring.png'));
    expect(result.pack.imageForDate(DateTime(2026, 6, 1)), path('default.png'));
  });

  test('supportsRangesThatCrossNewYear', () {
    touch('default.png');
    touch('new-year.png');
    final result = FarmPack.load(writeManifest(
        '{"name":"ChickPix","default":"default.png","variants":[{"start":"12-20","end":"01-05","image":"new-year.png"}]}'));

    expect(result.hasValue, isTrue, reason: result.error);
    expect(result.pack.imageForDate(DateTime(2026, 12, 25)), path('new-year.png'));
    expect(result.pack.imageForDate(DateTime(2027, 1, 5)), path('new-year.png'));
    expect(result.pack.imageForDate(DateTime(2027, 1, 6)), path('default.png'));
  });

  test('rejectsMissingReferencedImage', () {
    final result =
        FarmPack.load(writeManifest('{"name":"ChickPix","default":"default.png","variants":[]}'));
    expect(result.hasValue, isFalse);
    expect(result.error, contains('default'));
  });

  test('rejectsPathTraversal', () {
    touch('default.png');
    final result = FarmPack.load(
        writeManifest('{"name":"ChickPix","default":"../outside.png","variants":[]}'));
    expect(result.hasValue, isFalse);
    expect(result.error, contains('relative'));
  });

  test('rejectsMalformedManifest', () {
    final result = FarmPack.load(writeManifest('not json'));
    expect(result.hasValue, isFalse);
    expect(result.error, isNotEmpty);
  });
}
