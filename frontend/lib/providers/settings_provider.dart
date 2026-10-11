import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsState {
  const SettingsState({this.themeMode = ThemeMode.system, this.defaultExportQuality = 'standard'});

  final ThemeMode themeMode;
  final String defaultExportQuality; // "standard" | "high"

  SettingsState copyWith({ThemeMode? themeMode, String? defaultExportQuality}) => SettingsState(
        themeMode: themeMode ?? this.themeMode,
        defaultExportQuality: defaultExportQuality ?? this.defaultExportQuality,
      );
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier() : super(const SettingsState()) {
    _restore();
  }

  static const _themeKey = 'settings_theme_mode';
  static const _qualityKey = 'settings_export_quality';

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final themeStr = prefs.getString(_themeKey);
    final quality = prefs.getString(_qualityKey) ?? 'standard';
    final mode = switch (themeStr) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    state = state.copyWith(themeMode: mode, defaultExportQuality: quality);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  Future<void> setDefaultExportQuality(String quality) async {
    state = state.copyWith(defaultExportQuality: quality);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityKey, quality);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) => SettingsNotifier());
