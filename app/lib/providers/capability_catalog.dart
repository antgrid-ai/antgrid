import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/capability_catalog.dart';
import '../models/session_target.dart';
import '../services/capability_catalog_cache.dart';
import '../util/device_id.dart';

/// Cache-key source segment for a focused target. Catalogs differ per machine
/// (installed model set / auth), so remote targets key by bare deviceUuid; a
/// null target defaults to 'local' (harmless — no catalog is written for it).
String capabilitySourceKey(SessionTarget? target) {
  if (target == null || target.isLocal) return 'local';
  return 'machine:${baseDeviceUuid(target.registrationId)}';
}

/// Composite cache key: `<sourceKey>__<toolKey>`.
String capabilityCacheKey(String sourceKey, String toolKey) =>
    '${sourceKey}__$toolKey';

/// Swappable disk store so tests can inject a temp-rooted instance.
final capabilityCatalogCacheProvider = Provider<CapabilityCatalogCache>(
  (ref) => CapabilityCatalogCache(),
);

/// In-memory catalog map keyed by [capabilityCacheKey], lazily hydrated from
/// disk and updated on every successful (`ready`, non-empty) capabilities frame.
class CapabilityCatalogNotifier
    extends Notifier<Map<String, CapabilityCatalog>> {
  final Set<String> _hydrating = {};
  // Keys whose disk read has completed (loaded OR confirmed-absent). Distinct
  // from `_hydrating` (in-flight only): without this, a key with no file on disk
  // never enters `state`, so `containsKey` stays false and every rebuild re-hits
  // the disk. A later catalog for such a key only ever arrives via `remember`,
  // which writes `state` directly and takes precedence over this set.
  final Set<String> _read = {};

  @override
  Map<String, CapabilityCatalog> build() => const {};

  CapabilityCatalogCache get _cache => ref.read(capabilityCatalogCacheProvider);

  /// Load [key] from disk into memory once, if absent. Idempotent and safe to
  /// call from a build method (the returned future is for tests to await).
  Future<void> ensureHydrated(String key) async {
    if (state.containsKey(key) || _read.contains(key) || !_hydrating.add(key)) {
      return;
    }
    try {
      final c = await _cache.read(key);
      // A live frame may have landed while we read — don't clobber it.
      if (c != null && !state.containsKey(key)) {
        state = {...state, key: c};
      }
      // read() swallows its own errors and returns null, so reaching here means
      // the read genuinely completed — mark it done so an absent file isn't
      // re-read on every rebuild.
      _read.add(key);
    } finally {
      _hydrating.remove(key);
    }
  }

  /// Persist a freshly-discovered catalog (memory + disk). No-ops on empty.
  void remember(String key, CapabilityCatalog catalog) {
    if (catalog.isEmpty) return;
    state = {...state, key: catalog};
    unawaited(_cache.write(key, catalog));
  }
}

final capabilityCatalogProvider =
    NotifierProvider<CapabilityCatalogNotifier, Map<String, CapabilityCatalog>>(
      CapabilityCatalogNotifier.new,
    );
