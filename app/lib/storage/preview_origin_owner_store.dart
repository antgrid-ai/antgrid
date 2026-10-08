import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import '../demo/demo_identity.dart';
import '../util/ab_log.dart';

/// Persisted loopback port -> owner of the preview website data last written
/// on it, where an owner is a `ProjectSession.projectId`.
///
/// A missing, corrupt or unreadable record is "unknown history" ([read]
/// returns null), which is distinct from a known map with no entry for a port:
/// that port is clean. Every failure path degrades toward unknown, because a
/// false "clean" would let one project's service worker serve another's page.
///
/// `PreviewSiteData` is the only caller and serializes all access, so the
/// store has no lock of its own.
///
/// Cacheless [SharedPreferencesAsync] like `AgentCatalogStore`: written from
/// the admission path and read once per admission, so a cache buys nothing.
class PreviewOriginOwnerStore {
  PreviewOriginOwnerStore({SharedPreferencesAsync? prefs}) : _injected = prefs;

  /// Owner value meaning the data on that port may be mixed or of unknown
  /// origin. It never equals a real owner.
  static const unsettled = '';

  /// Past this the map is forgotten rather than grown, so a port with data can
  /// never silently read as clean.
  static const maxEntries = 1024;

  static final key = scopedStorageKey('antgrid.preview_origin_owners.v1');

  final SharedPreferencesAsync? _injected;

  // Constructing SharedPreferencesAsync throws when no platform is registered,
  // so it is created on first use, inside every caller's try block.
  late final SharedPreferencesAsync _prefs =
      _injected ?? SharedPreferencesAsync(options: desktopSharedPreferencesOptions);

  /// Null is unknown history. Never throws.
  Future<Map<int, String>?> read() async {
    try {
      final raw = await _prefs.getString(key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final out = <int, String>{};
      for (final e in decoded.entries) {
        final port = e.key is String ? int.tryParse(e.key as String) : null;
        final owner = e.value;
        if (port == null || port < 1 || port > 65535 || owner is! String) {
          return null;
        }
        out[port] = owner;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Overwrites [entries] into a known map; a no-op while history is unknown.
  Future<void> merge(Map<int, String> entries) async {
    try {
      final current = await read();
      if (current == null) return;
      final next = {...current, ..._withoutDemo(entries)};
      if (next.length > maxEntries) {
        await forget();
        return;
      }
      await _write(next);
    } catch (e) {
      await _writeFailed(e);
    }
  }

  /// Writes exactly [entries], making the map known.
  Future<void> replace(Map<int, String> entries) async {
    try {
      await _write(_withoutDemo(entries));
    } catch (e) {
      await _writeFailed(e);
    }
  }

  /// Back to unknown history.
  Future<void> forget() async {
    try {
      await _prefs.remove(key);
    } catch (e) {
      AbLog.warn(
        'preview',
        'origin owner forget failed',
        fields: {'error': '$e'},
      );
    }
  }

  // The demo must never reach disk (app/AGENTS.md).
  Map<int, String> _withoutDemo(Map<int, String> entries) => {
    for (final e in entries.entries)
      if (!isDemoEntryId(e.value)) e.key: e.value,
  };

  Future<void> _write(Map<int, String> entries) => _prefs.setString(
    key,
    jsonEncode({for (final e in entries.entries) '${e.key}': e.value}),
  );

  // A lost record must read as unknown, not as the stale map that survived.
  Future<void> _writeFailed(Object e) async {
    AbLog.warn(
      'preview',
      'origin owner write failed',
      fields: {'error': '$e'},
    );
    await forget();
  }
}
