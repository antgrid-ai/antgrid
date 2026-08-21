import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/environment.dart';
import '../config/storage_scope.dart';
import '../design/theme_presets.dart';
import '../storage/scoped_prefs.dart';

final _kDefaultRelayUrl = scopedStorageKey('app.defaultRelayUrl');
final _kThemePreset = scopedStorageKey('app.theme.preset');
final _kCustomBg = scopedStorageKey('app.theme.custom.bg');
final _kCustomPrimary = scopedStorageKey('app.theme.custom.primary');
final _kCustomAccent = scopedStorageKey('app.theme.custom.accent');
final _kUiScale = scopedStorageKey('antgrid.ui_scale.v1');
final _kTerminalZoom = scopedStorageKey('antgrid.terminal_zoom.v1');
final _kReduceMotion = scopedStorageKey('antgrid.reduce_motion.v1');
final _kFollowSystemBrightness = scopedStorageKey(
  'antgrid.follow_system_brightness.v1',
);
final _kTelemetryEnabled = scopedStorageKey('app.telemetry.enabled');
final _kSidebarHidden = scopedStorageKey('antgrid.sidebar_hidden.v1');

/// Every key AppSettings persists. The WithCache instance backing app settings
/// must allow exactly these — reads/writes of any other key throw.
final appSettingsPrefsKeys = <String>{
  _kDefaultRelayUrl,
  _kThemePreset,
  _kCustomBg,
  _kCustomPrimary,
  _kCustomAccent,
  _kUiScale,
  _kTerminalZoom,
  _kReduceMotion,
  _kFollowSystemBrightness,
  _kTelemetryEnabled,
  _kSidebarHidden,
};

@immutable
class AppSettings {
  const AppSettings({
    this.defaultRelayUrl,
    this.preset = AbThemePreset.zinc,
    this.customBg,
    this.customPrimary,
    this.customAccent,
    this.uiScale = 1.0,
    this.terminalZoom = 1.0,
    this.reduceMotion = false,
    this.followSystemBrightness = false,
    this.telemetryEnabled = true,
    this.sidebarHidden = false,
  });

  final String? defaultRelayUrl;
  final AbThemePreset preset;
  final Color? customBg;
  final Color? customPrimary;
  final Color? customAccent;
  final double uiScale;
  final double terminalZoom;
  final bool reduceMotion;
  final bool followSystemBrightness;
  final bool telemetryEnabled;

  /// Desktop projects-drawer visibility. App-wide rather than per-project (as
  /// `ProjectPreferences.panelMode` is): the drawer is how you MOVE between
  /// projects, so scoping its visibility to the focused one would flip it on
  /// every switch.
  final bool sidebarHidden;

  static const defaults = AppSettings();

  AppSettings copyWith({
    String? defaultRelayUrl,
    bool clearDefaultRelayUrl = false,
    AbThemePreset? preset,
    Color? customBg,
    Color? customPrimary,
    Color? customAccent,
    double? uiScale,
    double? terminalZoom,
    bool? reduceMotion,
    bool? followSystemBrightness,
    bool? telemetryEnabled,
    bool? sidebarHidden,
  }) {
    return AppSettings(
      defaultRelayUrl: clearDefaultRelayUrl
          ? null
          : (defaultRelayUrl ?? this.defaultRelayUrl),
      preset: preset ?? this.preset,
      customBg: customBg ?? this.customBg,
      customPrimary: customPrimary ?? this.customPrimary,
      customAccent: customAccent ?? this.customAccent,
      uiScale: uiScale ?? this.uiScale,
      terminalZoom: terminalZoom ?? this.terminalZoom,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      followSystemBrightness:
          followSystemBrightness ?? this.followSystemBrightness,
      telemetryEnabled: telemetryEnabled ?? this.telemetryEnabled,
      sidebarHidden: sidebarHidden ?? this.sidebarHidden,
    );
  }

  static AppSettings fromPrefs(SharedPreferencesWithCache prefs) {
    final presetName = prefs.getString(_kThemePreset);
    final preset = AbThemePreset.values.firstWhere(
      (p) => p.name == presetName,
      orElse: () => AbThemePreset.zinc,
    );
    Color? readColor(String key) {
      final v = prefs.getInt(key);
      return v == null ? null : Color(v);
    }

    return AppSettings(
      defaultRelayUrl: prefs.getString(_kDefaultRelayUrl),
      preset: preset,
      customBg: readColor(_kCustomBg),
      customPrimary: readColor(_kCustomPrimary),
      customAccent: readColor(_kCustomAccent),
      uiScale: prefs.getDouble(_kUiScale) ?? 1.0,
      terminalZoom: prefs.getDouble(_kTerminalZoom) ?? 1.0,
      reduceMotion: prefs.getBool(_kReduceMotion) ?? false,
      followSystemBrightness: prefs.getBool(_kFollowSystemBrightness) ?? false,
      telemetryEnabled: prefs.getBool(_kTelemetryEnabled) ?? true,
      sidebarHidden: prefs.getBool(_kSidebarHidden) ?? false,
    );
  }
}

class AppSettingsService extends Notifier<AppSettings> {
  AppSettingsService(this._prefs, this._seed);

  final SharedPreferencesWithCache _prefs;
  final AppSettings _seed;

  @override
  AppSettings build() => _seed;

  /// Persists the relay URL. Returns `null` on success, or a human-readable
  /// error message if the URL is malformed — caught at input rather than
  /// surfacing later as a stuck "Enabling…" button.
  Future<String?> setDefaultRelayUrl(String? url) async {
    final trimmed = url?.trim();
    final empty = trimmed == null || trimmed.isEmpty;
    if (!empty) {
      final error = _validateRelayUrl(trimmed);
      if (error != null) return error;
    }
    state = state.copyWith(
      defaultRelayUrl: empty ? null : trimmed,
      clearDefaultRelayUrl: empty,
    );
    if (empty) {
      await _prefs.remove(_kDefaultRelayUrl);
    } else {
      await _prefs.setString(_kDefaultRelayUrl, trimmed);
    }
    return null;
  }

  /// Mirrors the agent-side check in `startRelay`. `http(s)` is allowed
  /// alongside `ws(s)` because some dev setups upgrade at connect time.
  static String? _validateRelayUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Relay URL must include a scheme and host, e.g. wss://relay.example.com';
    }
    const allowed = {'ws', 'wss', 'http', 'https'};
    if (!allowed.contains(uri.scheme.toLowerCase())) {
      return 'Relay URL scheme "${uri.scheme}" is not supported. Use wss:// or ws://.';
    }
    return null;
  }

  Future<void> setPreset(AbThemePreset preset) async {
    state = state.copyWith(preset: preset);
    await _prefs.setString(_kThemePreset, preset.name);
  }

  Future<void> setCustomColors({
    Color? bg,
    Color? primary,
    Color? accent,
  }) async {
    state = state.copyWith(
      preset: AbThemePreset.custom,
      customBg: bg ?? state.customBg,
      customPrimary: primary ?? state.customPrimary,
      customAccent: accent ?? state.customAccent,
    );
    await _prefs.setString(_kThemePreset, AbThemePreset.custom.name);
    if (bg != null) await _prefs.setInt(_kCustomBg, _argb(bg));
    if (primary != null) await _prefs.setInt(_kCustomPrimary, _argb(primary));
    if (accent != null) await _prefs.setInt(_kCustomAccent, _argb(accent));
  }

  Future<void> setUiScale(double scale) async {
    state = state.copyWith(uiScale: scale);
    await _prefs.setDouble(_kUiScale, scale);
  }

  /// Bounds mirror the terminal pinch/step zoom range: below 0.5 text is
  /// unreadable, above 3.0 a single cell dwarfs the viewport.
  static const double minTerminalZoom = 0.5;
  static const double maxTerminalZoom = 3.0;

  Future<void> setTerminalZoom(double zoom) async {
    final clamped = zoom.clamp(minTerminalZoom, maxTerminalZoom);
    state = state.copyWith(terminalZoom: clamped);
    await _prefs.setDouble(_kTerminalZoom, clamped);
  }

  Future<void> setReduceMotion(bool enabled) async {
    state = state.copyWith(reduceMotion: enabled);
    await _prefs.setBool(_kReduceMotion, enabled);
  }

  Future<void> setFollowSystemBrightness(bool enabled) async {
    state = state.copyWith(followSystemBrightness: enabled);
    await _prefs.setBool(_kFollowSystemBrightness, enabled);
  }

  Future<void> setTelemetryEnabled(bool enabled) async {
    state = state.copyWith(telemetryEnabled: enabled);
    await _prefs.setBool(_kTelemetryEnabled, enabled);
  }

  Future<void> setSidebarHidden(bool hidden) async {
    state = state.copyWith(sidebarHidden: hidden);
    await _prefs.setBool(_kSidebarHidden, hidden);
  }

  Future<void> reset() async {
    state = AppSettings.defaults;
    await Future.wait([
      _prefs.remove(_kDefaultRelayUrl),
      _prefs.remove(_kThemePreset),
      _prefs.remove(_kCustomBg),
      _prefs.remove(_kCustomPrimary),
      _prefs.remove(_kCustomAccent),
      _prefs.remove(_kUiScale),
      _prefs.remove(_kTerminalZoom),
      _prefs.remove(_kReduceMotion),
      _prefs.remove(_kFollowSystemBrightness),
      _prefs.remove(_kTelemetryEnabled),
      _prefs.remove(_kSidebarHidden),
    ]);
  }
}

int _argb(Color c) =>
    ((c.a * 255).round() << 24) |
    ((c.r * 255).round() << 16) |
    ((c.g * 255).round() << 8) |
    (c.b * 255).round();

/// Opens the WithCache instance scoped to the app-settings keys. Shared by
/// `main.dart` and test setup so the allowList lives in one place.
Future<SharedPreferencesWithCache> openAppSettingsPrefs() =>
    openScopedPrefs(appSettingsPrefsKeys);

/// Overridden in `main.dart` with a prefs-seeded instance — calling the
/// default impl is a programmer error.
final appSettingsServiceProvider =
    NotifierProvider<AppSettingsService, AppSettings>(
      () => throw UnimplementedError(
        'appSettingsServiceProvider must be overridden in ProviderScope with a '
        'prefs-seeded AppSettingsService instance.',
      ),
    );

/// Compile-time relay URL baked in via `--dart-define=RELAY_URL=...`. Lets a
/// build point at a specific relay (e.g. staging) without anyone touching App
/// Settings. Empty (the default) means "no compile-time default".
const String relayUrlFromEnv = String.fromEnvironment('RELAY_URL');

/// Canonical relay URL source. Precedence: an explicit App Settings value the
/// user saved wins; otherwise the `RELAY_URL` dart-define; otherwise the
/// build-mode default (release → prod, debug/profile → staging). Always returns
/// a non-empty URL, so callers don't need their own fallback. For the local
/// full-stack loop pass `--dart-define=RELAY_URL=ws://localhost:3000`.
final defaultRelayUrlProvider = Provider<String>((ref) {
  final fromSettings = ref.watch(appSettingsServiceProvider).defaultRelayUrl;
  if (fromSettings != null && fromSettings.isNotEmpty) return fromSettings;
  if (relayUrlFromEnv.isNotEmpty) return relayUrlFromEnv;
  return AppEnvironment.relayUrl;
});
