// Replacement for src/qt/style.qss.
//
// Qt styled widgets with a CSS-like stylesheet keyed by objectName. Flutter uses a
// ThemeData for global defaults plus a few named text styles. The palette below is the
// same set of colors used in style.qss so the two builds look alike.

import 'package:material_ui/material_ui.dart';

class LauncherColors {
  LauncherColors._();

  static const window = Color(0xFFF1F2F3); // QWidget background
  static const text = Color(0xFF3F454A); // QWidget color
  static const heading = Color(0xFF30363B); // titles
  static const muted = Color(0xFF626C73); // status and metadata labels
  static const eyebrow = Color(0xFF747B80); // small caps labels
  static const panel = Color(0xFFFFFFFF); // lists, detail panels
  static const border = Color(0xFFD8DCDE);
  static const accent = Color(0xFFFFB703); // selected navigation item
  static const accentSoft = Color(0xFFFFE8AD); // hover/selected list items
  static const accentText = Color(0xFF2C627D); // text on accentSoft
  static const focus = Color(0xFF805900); // focus rings
  static const action = Color(0xFF4B9DCC); // primary actions (download, install)
  static const actionText = Color(0xFF182F3D);
  static const dropActive = Color(0xFFE8F2F6);
  static const statusBar = Color(0xFFE7E9EA);
}

class LauncherText {
  LauncherText._();

  // QLabel#sectionTitle, #modsTitle, #settingsTitle, ...
  static const sectionTitle =
      TextStyle(color: LauncherColors.heading, fontSize: 21, fontWeight: FontWeight.w600);
  // QLabel#detailTitle and #modTitle
  static const detailTitle =
      TextStyle(color: LauncherColors.heading, fontSize: 20, fontWeight: FontWeight.w600);
  // QLabel#eyebrow
  static const eyebrow = TextStyle(
      color: LauncherColors.eyebrow, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1);
  // QLabel#muted, #modListStatus, #modMetadata, ...
  static const muted = TextStyle(color: LauncherColors.muted, fontSize: 12);
}

/// @brief Builds the application theme equivalent to style.qss plus the Fusion style.
ThemeData buildLauncherTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: LauncherColors.action,
    primary: LauncherColors.action,
    onPrimary: LauncherColors.actionText,
    secondary: LauncherColors.accent,
    surface: LauncherColors.window,
    onSurface: LauncherColors.text,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: LauncherColors.window,
    textTheme: Typography.blackMountainView.apply(
      bodyColor: LauncherColors.text,
      displayColor: LauncherColors.heading,
    ),
    dividerColor: LauncherColors.border,
    visualDensity: VisualDensity.compact,
    listTileTheme: const ListTileThemeData(
      selectedColor: LauncherColors.accentText,
      selectedTileColor: LauncherColors.accentSoft,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
      filled: true,
      fillColor: LauncherColors.panel,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LauncherColors.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LauncherColors.action,
        foregroundColor: LauncherColors.actionText,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
  );
}
