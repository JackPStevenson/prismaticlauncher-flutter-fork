// Port of src/smapi/SmapiManager.{h,cpp}.

import 'dart:io';

import 'smapi_detector.dart';
import 'smapi_launcher.dart';

enum LaunchStatus { success, smapiNotInstalled, launchFailed, unsupportedPlatform }

/// @brief Describes the result of launching SMAPI.
class LaunchResult {
  const LaunchResult({required this.status, required this.message});

  final LaunchStatus status;
  final String message;

  /// @brief Returns true only when the launch has succeeded.
  bool get succeeded => status == LaunchStatus.success;
}

/// @brief Inspects the user's SMAPI installation and launches the modded game.
class SmapiManager {
  /// @brief Takes the launcher used to start SMAPI after a successful inspection.
  SmapiManager(this._launcher);

  final SmapiDetector _detector = const SmapiDetector();
  final SmapiLauncher _launcher;

  /// @brief Inspects SMAPI in [gameDirectory] without modifying any files.
  SmapiInstallation inspect(String gameDirectory) => _detector.inspect(gameDirectory);

  /// @brief Returns true when SMAPI is completely installed in [gameDirectory].
  bool isInstalled(String gameDirectory) => inspect(gameDirectory).isInstalled;

  /// @brief Launches the modded game using the attached launcher after verification.
  Future<LaunchResult> launch(String gameDirectory, [String arguments = '']) async {
    if (!inspect(gameDirectory).isInstalled) {
      return const LaunchResult(
          status: LaunchStatus.smapiNotInstalled,
          message: 'SMAPI is not installed or its installation is incomplete.');
    }

    // Port note: this mirrors the C++ `#ifdef _WIN32` exactly, including its quirk: the
    // launcher is only called on Windows, while SmapiLauncher only implements Linux. The
    // instance window launches the game itself, so this path is currently only exercised
    // by tests. Behavior is kept identical so both versions can be compared.
    if (!Platform.isWindows) {
      return const LaunchResult(
          status: LaunchStatus.unsupportedPlatform,
          message: 'SMAPI launching is not implemented for this platform yet.');
    }

    final launched = await _launcher.launch(gameDirectory, arguments);
    return launched
        ? const LaunchResult(
            status: LaunchStatus.success, message: 'Stardew Valley started through SMAPI.')
        : const LaunchResult(
            status: LaunchStatus.launchFailed,
            message: 'Unable to start Stardew Valley through SMAPI.');
  }
}
