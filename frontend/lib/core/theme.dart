import 'package:flutter/material.dart';

/// A hand-rolled, ChatGPT-like design system: flat, calm, neutral-gray
/// surfaces, a single accent color, no gradients, no neon. Deliberately
/// restrained -- this app is a utility, not a marketing page.
class AppColors {
  AppColors._();

  // Light theme
  static const lightBg = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF7F7F8);
  static const lightSurfaceAlt = Color(0xFFECECF1);
  static const lightBorder = Color(0xFFE3E3E8);
  static const lightText = Color(0xFF0D0D0D);
  static const lightTextMuted = Color(0xFF6E6E80);

  // Dark theme
  static const darkBg = Color(0xFF212121);
  static const darkSurface = Color(0xFF2A2A2A);
  static const darkSurfaceAlt = Color(0xFF343434);
  static const darkBorder = Color(0xFF3E3E42);
  static const darkText = Color(0xFFECECEC);
  static const darkTextMuted = Color(0xFFABABAB);

  // Shared accent -- a single calm blue/teal, used sparingly for primary
  // actions and active states, never as a background wash.
  static const accent = Color(0xFF10A37F);
  static const accentMuted = Color(0xFFD6F0E7);

  static const danger = Color(0xFFD93025);
  static const warning = Color(0xFFB7791F);
  static const success = Color(0xFF10A37F);
}

class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class AppRadius {
  AppRadius._();
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
  static const pill = 999.0;
}

ThemeData buildAppTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final bg = isDark ? AppColors.darkBg : AppColors.lightBg;
  final surface = isDark ? AppColors.darkSurface : AppColors.lightSurface;
  final border = isDark ? AppColors.darkBorder : AppColors.lightBorder;
  final text = isDark ? AppColors.darkText : AppColors.lightText;
  final textMuted = isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted;

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: AppColors.accent,
    onPrimary: Colors.white,
    secondary: AppColors.accent,
    onSecondary: Colors.white,
    error: AppColors.danger,
    onError: Colors.white,
    surface: surface,
    onSurface: text,
  );

  return ThemeData(
    brightness: brightness,
    useMaterial3: true,
    scaffoldBackgroundColor: bg,
    colorScheme: colorScheme,
    fontFamily: 'Segoe UI',
    textTheme: TextTheme(
      displaySmall: TextStyle(color: text, fontWeight: FontWeight.w600),
      headlineMedium: TextStyle(color: text, fontWeight: FontWeight.w600, fontSize: 24),
      headlineSmall: TextStyle(color: text, fontWeight: FontWeight.w600, fontSize: 20),
      titleLarge: TextStyle(color: text, fontWeight: FontWeight.w600, fontSize: 17),
      titleMedium: TextStyle(color: text, fontWeight: FontWeight.w500, fontSize: 15),
      bodyLarge: TextStyle(color: text, fontSize: 15),
      bodyMedium: TextStyle(color: text, fontSize: 14),
      bodySmall: TextStyle(color: textMuted, fontSize: 13),
      labelLarge: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: border),
      ),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
      hintStyle: TextStyle(color: textMuted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: textMuted.withOpacity(0.3),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: BorderSide(color: border),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark ? AppColors.darkSurfaceAlt : AppColors.lightText,
      contentTextStyle: TextStyle(color: isDark ? AppColors.darkText : Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
  );
}
