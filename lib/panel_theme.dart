import 'package:flutter/material.dart';

abstract final class PanelStyle {
  static final surface = const Color(0xFF202020).withValues(alpha: 0.5);
  static final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(10),
    side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
  );
}

ThemeData buildPanelTheme() => ThemeData(
  fontFamily: 'Segoe UI',
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF8792A4),
        brightness: Brightness.dark,
      ).copyWith(
        surface: PanelStyle.surface,
        surfaceTint: Colors.transparent,
        inverseSurface: PanelStyle.surface,
        onInverseSurface: Colors.white,
      ),
  scaffoldBackgroundColor: Colors.transparent,
  cardColor: PanelStyle.surface,
  canvasColor: PanelStyle.surface,
  shadowColor: Colors.transparent,
  applyElevationOverlayColor: false,
  splashFactory: InkRipple.splashFactory,
  dialogTheme: DialogThemeData(
    backgroundColor: PanelStyle.surface,
    barrierColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    elevation: 0,
    shape: PanelStyle.shape,
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: PanelStyle.surface,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    elevation: 0,
    shape: PanelStyle.shape,
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: PanelStyle.surface,
    elevation: 0,
    shape: PanelStyle.shape,
    contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
    actionTextColor: Colors.white70,
  ),
  tooltipTheme: TooltipThemeData(
    decoration: BoxDecoration(
      color: PanelStyle.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
    ),
    textStyle: const TextStyle(color: Colors.white, fontSize: 12, height: 1.3),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    waitDuration: const Duration(milliseconds: 500),
    showDuration: const Duration(seconds: 3),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: Colors.white70),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white24),
    ),
  ),
);
