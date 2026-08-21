import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'scoped_prefs.dart';

import '../config/storage_scope.dart';
import '../models/session_entry.dart';

/// SharedPreferences-backed cache of `List<SessionEntry>` keyed by drawer entry
/// id (`projectId` for local projects, `agentDeviceId` for paired remotes).
/// Written-through by `SessionsService` so an expanded but inactive drawer
/// panel still shows its sessions.
///
/// Writes are debounced to coalesce rapid `session:updated` bursts (the agent
/// emits two frames per mutation — sync `changed()` + async PTY `noteExited`).
/// Tests can force a flush via [flushNow].
class CachedSessionsStore {
  static final _key = scopedStorageKey('antgrid.session_cache.v1');
  // Labels churn far more often than the session list itself (every live
  // control-plane advert, one project at a time via putLabel) — a separate
  // key lets a label-only flush skip re-encoding every cached session.
  static final _labelsKey = scopedStorageKey('antgrid.session_cache.labels.v1');
  // Last-seen per-project work status from live control-plane adverts. Persisted
  // so a cold boot can seed remoteProjectStatusProvider with the last-known
  // call-to-action (attention/error) before the first advert arrives; the seed
  // deliberately ignores working/done — "working" means a prompt is in flight
  // right now, which a value from a previous launch cannot know (see
  // remoteProjectStatusProvider.build). Cleared per machine
  // on socket close so an offline machine doesn't re-seed on the next boot.
  static final _statusKey = scopedStorageKey('antgrid.session_cache.status.v1');
  static const _flushDebounce = Duration(milliseconds: 200);

  final SharedPreferencesWithCache _prefs;
  final StreamController<String> _changes =
      StreamController<String>.broadcast();
  final Map<String, List<SessionEntry>> _mem = {};
  // Last-seen human project label per entryId, from a live control-plane
  // advert. Persisted alongside the sessions so an offline/cold-boot Recent
  // row can fall back to a real name instead of the raw projectId.
  final Map<String, String> _labels = {};
  final Map<String, String> _statuses = {};
  bool _entriesDirty = false;
  bool _labelsDirty = false;
  bool _statusesDirty = false;
  Timer? _flushTimer;

  CachedSessionsStore._(this._prefs) {
    _loadFromDisk();
  }

  static Future<CachedSessionsStore> open() async => CachedSessionsStore._(
    await openScopedPrefs({_key, _labelsKey, _statusKey}),
  );

  /// Returns an unmodifiable view of the cached sessions for [entryId], or
  /// `const []` if nothing is cached.
  List<SessionEntry> get(String entryId) =>
      List.unmodifiable(_mem[entryId] ?? const <SessionEntry>[]);

  /// Whether [entryId] has ever been seeded — true even for a project cached
  /// with zero sessions. Distinct from `get(entryId).isEmpty`, which can't
  /// tell "never synced" from "synced, genuinely no sessions".
  bool has(String entryId) => _mem.containsKey(entryId);

  /// Unmodifiable snapshot of every cached `entryId → sessions`. The Recent tab
  /// aggregates over this to build a cross-project flat list. Lists are already
  /// unmodifiable (stored that way by [put]); the outer map is copied so callers
  /// can't mutate `_mem`.
  Map<String, List<SessionEntry>> entries() => Map.unmodifiable(_mem);

  /// Replace the cached list for [entryId]. No-ops if the encoded list is
  /// identical to the in-memory one. Writes are debounced; [changes] still
  /// emits on the next microtask so listeners can react synchronously.
  Future<void> put(String entryId, List<SessionEntry> sessions) async {
    final prev = _mem[entryId];
    if (prev != null && _listsEqual(prev, sessions)) return;
    _mem[entryId] = List.unmodifiable(sessions);
    _entriesDirty = true;
    if (!_changes.isClosed) _changes.add(entryId);
    _scheduleFlush();
  }

  /// Drop [entryId] from the cache. Emits on [changes] and flushes per the
  /// usual debounce so the SharedPreferences blob actually shrinks.
  Future<void> removeKey(String entryId) async {
    if (!_mem.containsKey(entryId)) return;
    _mem.remove(entryId);
    _entriesDirty = true;
    if (!_changes.isClosed) _changes.add(entryId);
    _scheduleFlush();
  }

  /// Drops every cached session, label and status in one shot. Used by hard
  /// sign-out: the whole cache describes machines reachable under the account
  /// that is going away, so a re-sign-in (possibly as a DIFFERENT user) must not
  /// find another account's session names and project labels already on screen.
  ///
  /// Flushes synchronously rather than leaving it to the debounce — sign-out's
  /// next steps drop the credentials, and a timer that fires after the app is
  /// signed out is not something the caller can wait on.
  Future<void> clear() async {
    final cleared = _mem.keys.toList(growable: false);
    _mem.clear();
    _labels.clear();
    _statuses.clear();
    _entriesDirty = true;
    _labelsDirty = true;
    _statusesDirty = true;
    for (final entryId in cleared) {
      if (!_changes.isClosed) _changes.add(entryId);
    }
    await flushNow();
  }

  /// Last-seen human project label for [entryId], or `null` if never observed.
  String? label(String entryId) => _labels[entryId];

  /// Unmodifiable snapshot of every persisted `entryId → project label`.
  Map<String, String> labels() => Map.unmodifiable(_labels);

  /// Record the last-seen live project label for [entryId]. No-ops if
  /// unchanged. Debounced flush like [put]; does not emit on [changes] — a
  /// label update alone shouldn't force every listener to re-derive its
  /// session list.
  void putLabel(String entryId, String label) {
    if (_labels[entryId] == label) return;
    _labels[entryId] = label;
    _labelsDirty = true;
    _scheduleFlush();
  }

  /// Last-seen raw work-status string for [entryId] (`"working"` /
  /// `"attention"` / `"done"` / `"error"`), or `null` if never observed.
  /// Callers parse via `AgentWorkStatus.fromWire`.
  String? statusOf(String entryId) => _statuses[entryId];

  /// Unmodifiable snapshot of every persisted `entryId → raw status string`.
  Map<String, String> allStatuses() => Map.unmodifiable(_statuses);

  /// Record the last-seen live work status for [entryId]. Persisted so a cold
  /// boot can seed the status map before the first advert arrives. No-ops if
  /// unchanged; does not emit on [changes].
  void putStatus(String entryId, String status) {
    if (_statuses[entryId] == status) return;
    _statuses[entryId] = status;
    _statusesDirty = true;
    _scheduleFlush();
  }

  /// Drop status entries for every key starting with [machinePrefix] (e.g.
  /// `"$uuid."`) — called when a machine socket closes so stale statuses
  /// don't seed the next cold boot with data from a disconnected machine.
  void clearStatusesForMachine(String machinePrefix) {
    final toRemove = _statuses.keys
        .where((k) => k.startsWith(machinePrefix))
        .toList(growable: false);
    if (toRemove.isEmpty) return;
    for (final k in toRemove) {
      _statuses.remove(k);
    }
    _statusesDirty = true;
    _scheduleFlush();
  }

  /// Broadcast stream of `entryId`s that just changed. Does NOT replay; callers
  /// should seed from [get] and then listen.
  Stream<String> get changes => _changes.stream;

  /// Force pending writes through immediately. Production code doesn't need
  /// this; tests use it to make round-trips deterministic.
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }

  Future<void> close() async {
    await flushNow();
    await _changes.close();
  }

  void _loadFromDisk() {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        final entries = decoded is Map ? decoded['entries'] : null;
        if (entries is Map) {
          entries.forEach((k, v) {
            if (k is! String || v is! List) return;
            final list = <SessionEntry>[];
            for (final item in v) {
              if (item is Map<String, dynamic>) {
                try {
                  // `running` is in-memory state only — even if an older build
                  // persisted it, force false on load so a fresh launch never
                  // resurrects a stale green status dot.
                  list.add(SessionEntry.fromJson({...item, 'running': false}));
                } catch (_) {
                  /* skip malformed */
                }
              }
            }
            _mem[k] = List.unmodifiable(list);
          });
        }
        // Pre-split-key installs persisted labels embedded in this same blob
        // (see _labelsKey) — load them so upgrading doesn't drop every
        // already-observed project label back to showing the raw id.
        final legacyLabels = decoded is Map ? decoded['labels'] : null;
        if (legacyLabels is Map) {
          legacyLabels.forEach((k, v) {
            if (k is String && v is String) _labels[k] = v;
          });
        }
      } catch (_) {
        // Corrupt blob — treat as empty. Next write replaces it.
      }
    }
    final rawLabels = _prefs.getString(_labelsKey);
    if (rawLabels != null) {
      try {
        final decoded = jsonDecode(rawLabels);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is String) _labels[k] = v;
          });
        }
      } catch (_) {
        // Corrupt blob — treat as empty. Next write replaces it.
      }
    }
    final rawStatuses = _prefs.getString(_statusKey);
    if (rawStatuses != null) {
      try {
        final decoded = jsonDecode(rawStatuses);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is String) _statuses[k] = v;
          });
        }
      } catch (_) {
        // Corrupt blob — treat as empty. Next write replaces it.
      }
    }
  }

  void _scheduleFlush() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(_flushDebounce, () {
      _flushTimer = null;
      _flush();
    });
  }

  Future<void> _flush() async {
    if (_entriesDirty) {
      _entriesDirty = false;
      // Strip `running` and `workStatus` before persisting: both are
      // process-lifetime state owned by SessionsService, not durable metadata.
      // A restored `running` renders sessions as live before the agent reports;
      // a restored `attention` claims an agent is blocked on a prompt that died
      // with the process.
      final encoded = jsonEncode({
        'version': 1,
        'entries': _mem.map(
          (k, v) => MapEntry(
            k,
            v.map((s) {
              // Non-mutating copy: don't assume `toJson()` returns a fresh map.
              final j = {...s.toJson(), 'running': false};
              j.remove('workStatus');
              return j;
            }).toList(),
          ),
        ),
      });
      if (_prefs.getString(_key) != encoded) {
        await _prefs.setString(_key, encoded);
      }
    }
    if (_labelsDirty) {
      _labelsDirty = false;
      final encoded = jsonEncode(_labels);
      if (_prefs.getString(_labelsKey) != encoded) {
        await _prefs.setString(_labelsKey, encoded);
      }
    }
    if (_statusesDirty) {
      _statusesDirty = false;
      final encoded = jsonEncode(_statuses);
      if (_prefs.getString(_statusKey) != encoded) {
        await _prefs.setString(_statusKey, encoded);
      }
    }
  }

  bool _listsEqual(List<SessionEntry> a, List<SessionEntry> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
