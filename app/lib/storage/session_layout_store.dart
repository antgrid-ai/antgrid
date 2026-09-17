import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import '../demo/demo_identity.dart';
import 'scoped_prefs.dart';

/// One session's persisted workspace layout.
///
/// Deliberately only the geometry a user arranges by hand. Runtime state
/// (`pinnedTerminalId`, `pushedTerminalId`) names things that may not exist on
/// the next launch, and restoring it would point the panel at a terminal the
/// bridge has forgotten.
class SessionLayout {
  const SessionLayout({this.panelMode, this.splitRatio, this.workspaceViewIndex});

  final String? panelMode;
  final double? splitRatio;
  final int? workspaceViewIndex;

  bool get isEmpty =>
      panelMode == null && splitRatio == null && workspaceViewIndex == null;

  Map<String, dynamic> toJson() => {
    if (panelMode != null) 'panelMode': panelMode,
    if (splitRatio != null) 'splitRatio': splitRatio,
    if (workspaceViewIndex != null) 'workspaceViewIndex': workspaceViewIndex,
  };

  static SessionLayout fromJson(Map<String, dynamic> json) => SessionLayout(
    panelMode: json['panelMode'] as String?,
    splitRatio: (json['splitRatio'] as num?)?.toDouble(),
    workspaceViewIndex: json['workspaceViewIndex'] as int?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLayout &&
          other.panelMode == panelMode &&
          other.splitRatio == splitRatio &&
          other.workspaceViewIndex == workspaceViewIndex;

  @override
  int get hashCode => Object.hash(panelMode, splitRatio, workspaceViewIndex);
}

/// SharedPreferences-backed per-session workspace layout, so a panel width or
/// mode a user arranged survives a restart rather than resetting to the
/// project's seed.
///
/// Keyed by `entryId|sessionId` — the same pair as `SessionUiKey`. Sessions are
/// created and deleted freely and nothing walks this map to reconcile it
/// against a live session list, so it is bounded two ways instead: entries are
/// dropped by [forget] when a session is deleted, and the whole map is capped
/// at [_maxEntries] in insertion order, oldest out first. A stale key that
/// never matches a live session is harmless beyond the space it occupies.
class SessionLayoutStore {
  static final _key = scopedStorageKey('antgrid.session_layout.v1');

  /// Insertion-ordered cap. Layout is a convenience, not data the user would
  /// miss: losing the oldest entry costs one session its remembered width.
  static const _maxEntries = 400;

  final SharedPreferencesWithCache? _prefs;
  final Map<String, SessionLayout> _mem = {};

  /// A store that remembers for this launch and writes nothing.
  ///
  /// The DEFAULT for [sessionLayoutStoreProvider], unlike its siblings
  /// (`drawerCollapsedStoreProvider` and friends) which throw until `main()`
  /// overrides them. Those are read from one place each; this one is read by
  /// every `SessionWorkspaceController`, which every workspace widget reaches
  /// transitively — so a throwing default turns a missing override into a
  /// crash across the whole workspace, and into harness noise in every widget
  /// test that never cared about persistence. Layout is a convenience, so
  /// degrading to "remembers until quit" is the proportionate failure.
  SessionLayoutStore.inMemory() : _prefs = null;

  SessionLayoutStore._(this._prefs) {
    final raw = _prefs!.getString(_key);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          _mem[entry.key] = SessionLayout.fromJson(value);
        }
      }
    } catch (_) {
      // A corrupt blob costs remembered layouts, never a launch.
      _mem.clear();
    }
  }

  /// Read into memory at construction so [read] can answer SYNCHRONOUSLY:
  /// `SessionWorkspaceController.build()` is what makes a session switch land
  /// in one frame, and an async read there would put the lag straight back.
  static Future<SessionLayoutStore> open() async =>
      SessionLayoutStore._(await openScopedPrefs({_key}));

  static String keyFor(String entryId, String sessionId) =>
      '$entryId|$sessionId';

  SessionLayout? read(String entryId, String sessionId) =>
      _mem[keyFor(entryId, sessionId)];

  Future<void> write(
    String entryId,
    String sessionId,
    SessionLayout layout,
  ) async {
    // The sample project's sessions arrange like any other, but their ids name
    // nothing the real app can resolve and nothing prunes them.
    if (isDemoEntryId(entryId)) return;
    if (layout.isEmpty) return;
    final key = keyFor(entryId, sessionId);
    // Remove before insert so a re-written entry counts as the NEWEST for the
    // cap below, rather than keeping its original position and being evicted
    // while still in active use.
    _mem.remove(key);
    _mem[key] = layout;
    while (_mem.length > _maxEntries) {
      _mem.remove(_mem.keys.first);
    }
    await _save();
  }

  Future<void> forget(String entryId, String sessionId) async {
    if (_mem.remove(keyFor(entryId, sessionId)) == null) return;
    await _save();
  }

  /// Drops every session's layout. Used by hard sign-out, alongside the other
  /// per-account caches: these ids name the previous account's sessions.
  Future<void> clear() async {
    _mem.clear();
    await _save();
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      _key,
      jsonEncode({
        for (final e in _mem.entries) e.key: e.value.toJson(),
      }),
    );
  }
}
