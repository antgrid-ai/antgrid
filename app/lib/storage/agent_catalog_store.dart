import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import '../models/agent_descriptor.dart';

/// Persisted registry key -> [AgentDescriptor], merged across every machine
/// this app has talked to.
///
/// Safe to cache indefinitely and to merge across machines because the
/// descriptor is a projection of the bridge's STATIC registry — nothing in it
/// reads a filesystem (see `bridge/src/agent-catalog.ts`). That is what lets a
/// cached session row from an offline machine still be named and described,
/// which the PATH-scoped `tools[]` advert structurally cannot do.
///
/// Cacheless [SharedPreferencesAsync] rather than the `WithCache` flavour every
/// other store in this directory uses: this key is written from the app-shell
/// reaper and read once at provider construction, so an in-process cache would
/// buy nothing and the single-owner rule in `scoped_prefs.dart` would have to be
/// upheld for a third writer.
class AgentCatalogStore {
  static final _key = scopedStorageKey('antgrid.agent_catalog.v1');

  final SharedPreferencesAsync _prefs;

  AgentCatalogStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  /// Empty on a cold install, and on anything unreadable — a corrupt blob or an
  /// unavailable prefs platform is a cache miss, never a crash on the launch
  /// path, because every consumer already has to handle "nobody has said".
  Future<Map<String, AgentDescriptor>> read() async {
    try {
      final raw = await _prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, AgentDescriptor>{};
      for (final e in decoded.entries) {
        final key = e.key;
        final value = e.value;
        if (key is! String || value is! Map) continue;
        final d = AgentDescriptor.fromJson(value.cast<String, dynamic>());
        if (d != null) out[key] = d;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<void> write(Map<String, AgentDescriptor> catalog) => _prefs.setString(
    _key,
    jsonEncode({for (final e in catalog.entries) e.key: e.value.toJson()}),
  );
}
