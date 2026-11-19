// Port of tests/smapi/SmapiDetectorTests.cpp and tests/smapi/SmapiTests.cpp.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:prismatic_launcher/common/error_message.dart';
import 'package:prismatic_launcher/smapi/managed_assembly_version_reader.dart';
import 'package:prismatic_launcher/smapi/smapi_detector.dart';
import 'package:prismatic_launcher/smapi/smapi_launcher.dart';
import 'package:prismatic_launcher/smapi/smapi_manager.dart';
import 'package:prismatic_launcher/smapi/smapi_version.dart';

import 'smapi_fixture.dart';

void main() {
  late String temp;
  setUp(() => temp = temporaryDirectory(addTearDown).path);

  group('SmapiDetectorTests', () {
    test('readsManagedAssemblyVersion', () {
      final path = p.join(temp, 'SMAPI.Toolkit.dll');
      writeFile(path, managedAssemblyFixture(4, 5, 2));

      final error = ErrorMessage();
      final version = const ManagedAssemblyVersionReader().read(path, error);
      expect(version, isNotNull, reason: error.value);
      expect(version.toString(), '4.5.2');
    });

    test('rejectsNonAssemblyFiles', () {
      final path = p.join(temp, 'not-an-assembly.dll');
      writeFile(path, 'not a PE file'.codeUnits);

      final error = ErrorMessage();
      expect(const ManagedAssemblyVersionReader().read(path, error), isNull);
      expect(error.value, isNotEmpty);
    });

    test('detectsInstalledSmapiAndVersion', () {
      const expected = SmapiVersion(major: 4, minor: 5, patch: 2);
      createSmapiFixture(temp, expected, expected);

      final installation = const SmapiDetector().inspect(temp);
      expect(installation.state, SmapiState.installed);
      expect(installation.isInstalled, isTrue);
      expect(installation.version.toString(), '4.5.2');
    });

    // Detects SMAPI when its metadata contains comments and literal comment-like strings.
    test('acceptsCommentedMetadata', () {
      const metadata = '{ /* Bundled SMAPI metadata */\n'
          '  // Comments are supported by SMAPI.\n'
          '  "Mods": { "Url": "https://example.com/*literal*/" }\n'
          '}';
      const version = SmapiVersion(major: 4, minor: 5, patch: 2);
      createSmapiFixture(temp, version, version, metadata);

      final installation = const SmapiDetector().inspect(temp);
      expect(installation.isInstalled, isTrue, reason: installation.diagnostic);
      expect(installation.version.toString(), '4.5.2');
    });

    test('detectsMacBundleInstallation', () {
      final bundle = p.join(temp, 'Stardew Valley.app');
      final executableDirectory = p.join(bundle, 'Contents', 'MacOS');
      const version = SmapiVersion(major: 4, minor: 5, patch: 2);
      createSmapiFixture(executableDirectory, version, version);

      final installation = const SmapiDetector().inspect(bundle);
      expect(installation.isInstalled, isTrue, reason: installation.diagnostic);
      expect(installation.gameDirectory, executableDirectory);
      expect(installation.executablePath, p.join(executableDirectory, 'StardewModdingAPI'));
    }, skip: !Platform.isMacOS);

    test('reportsNotInstalledForPlainDirectory', () {
      final installation = const SmapiDetector().inspect(temp);
      expect(installation.state, SmapiState.notInstalled);
      expect(installation.isInstalled, isFalse);
    });

    test('ignoresLegacyRootMetadataMarker', () {
      writeFile(p.join(temp, 'StardewModdingAPI.metadata.json'), '{}'.codeUnits);
      expect(const SmapiDetector().inspect(temp).state, SmapiState.notInstalled);
    });

    test('reportsInvalidGamePath', () {
      final installation = const SmapiDetector().inspect(p.join(temp, 'missing-game'));
      expect(installation.state, SmapiState.invalidGamePath);
    });

    test('reportsIncompleteInstallation', () {
      writeEmptyFile(p.join(temp, 'StardewModdingAPI.dll'));

      final installation = const SmapiDetector().inspect(temp);
      expect(installation.state, SmapiState.incomplete);
      expect(installation.diagnostic, contains('smapi-internal/'));
    });

    test('reportsMismatchedComponentVersions', () {
      createSmapiFixture(temp, const SmapiVersion(major: 4, minor: 5, patch: 2),
          const SmapiVersion(major: 4, minor: 5, patch: 1));

      final installation = const SmapiDetector().inspect(temp);
      expect(installation.state, SmapiState.componentMismatch);
      expect(installation.diagnostic, contains('4.5.2'));
      expect(installation.diagnostic, contains('4.5.1'));
    });

    test('rejectsInvalidMetadata', () {
      const version = SmapiVersion(major: 4, minor: 5, patch: 2);
      createSmapiFixture(temp, version, version, 'not json');

      final installation = const SmapiDetector().inspect(temp);
      expect(installation.state, SmapiState.incomplete);
      expect(installation.diagnostic, contains('valid JSON'));
    });
  });

  group('SmapiTests', () {
    test('managerRejectsMissingGameDirectory', () {
      final manager = SmapiManager(const SmapiLauncher());
      expect(manager.inspect(p.join(temp, 'missing')).state, SmapiState.invalidGamePath);
    });

    test('managerReportsMissingInstallation', () {
      final result = SmapiManager(const SmapiLauncher()).inspect(temp);
      expect(result.state, SmapiState.notInstalled);
      expect(result.isInstalled, isFalse);
    });

    // Reports SMAPI as absent and rejects launching from an empty directory.
    test('managerRejectsLaunchWithoutSmapi', () async {
      final manager = SmapiManager(const SmapiLauncher());
      // The empty directory triggers the installation guard before platform-specific launching.
      expect(manager.isInstalled(temp), isFalse);
      final result = await manager.launch(temp);
      expect(result.status, LaunchStatus.smapiNotInstalled);
      expect(result.succeeded, isFalse);
    });

    // Makes the launcher return false when the SMAPI executable is missing.
    test('launcherRejectsMissingExecutable', () async {
      expect(await const SmapiLauncher().launch(temp), isFalse);
    });

    test('splitArgumentsHandlesQuotesAndEscapes', () {
      expect(
          splitArguments(r'''--mods "My Mods" 'a b' c\ d'''), ['--mods', 'My Mods', 'a b', 'c d']);
      expect(splitArguments('"unterminated'), isNull);
    });
  });
}
