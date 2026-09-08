import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';

/// Opens a [SharedPreferencesWithCache] whose cache is scoped to exactly [keys].
///
/// Every persisted store funnels through here so the WithCache construction —
/// and its allowList contract (reads/writes of an unlisted key throw
/// `ArgumentError`) — lives in one place. The cache is per-instance, so a given
/// key must be owned by a SINGLE store; two instances caching the same key
/// drift on write. The one cross-store key (`antgrid.local_host_uuid`) is
/// deliberately read via cacheless [SharedPreferencesAsync] for that reason —
/// see `kLocalHostUuidKey`.
///
/// [desktopSharedPreferencesOptions] MUST be passed here — see its doc for why
/// a bare default on desktop shares a single physical file (and a single
/// plugin-side write path) with any other build on the machine.
Future<SharedPreferencesWithCache> openScopedPrefs(Set<String> keys) =>
    SharedPreferencesWithCache.create(
      cacheOptions: SharedPreferencesWithCacheOptions(allowList: keys),
      sharedPreferencesOptions: desktopSharedPreferencesOptions,
    );
