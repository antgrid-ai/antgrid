import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import '../demo/demo_identity.dart';
import 'scoped_prefs.dart';

/// A remembered preview target: a port plus the scheme it was last opened with.
class RecentPort {
  final int port;
  final String scheme; // 'http' | 'https'
  const RecentPort(this.port, this.scheme);

  Map<String, dynamic> toJson() => {'port': port, 'scheme': scheme};

  @override
  bool operator ==(Object other) =>
      other is RecentPort && other.port == port && other.scheme == scheme;

  @override
  int get hashCode => Object.hash(port, scheme);
}

/// One project's remembered ports, emitted on [RecentPortsStore.changes].
class RecentPortsChange {
  final String projectId;
  final List<RecentPort> ports;
  const RecentPortsChange(this.projectId, this.ports);
}

/// SharedPreferences-backed list of manually-entered preview targets, keyed by
/// project. Detection (`ports:update` / `preview:snapshot`) is the normal way
/// ports appear; this store backs the manual-entry fallback so a target typed
/// once is offered as a quick-pick — with its scheme — next time.
///
/// Stored under a single JSON key
/// (`{ "<projectId>": [{"port":3000,"scheme":"http"}] }`) so each write is
/// atomic. Per project the list is most-recent-first, deduped by port (one
/// entry per port carrying its latest scheme), and capped at [_capPerProject].
/// Mirrors [RecentAgentsStore]'s snapshot-on-write model: every mutation emits
/// a fresh immutable list on [changes].
class RecentPortsStore {
  static final _key = scopedStorageKey('antgrid.recent_ports.v1');
  static const _capPerProject = 8;

  final SharedPreferencesWithCache _prefs;
  final StreamController<RecentPortsChange> _changes =
      StreamController<RecentPortsChange>.broadcast();

  RecentPortsStore._(this._prefs);

  static Future<RecentPortsStore> open() async =>
      RecentPortsStore._(await openScopedPrefs({_key}));

  Map<String, List<RecentPort>> _readAll() {
    final raw = _prefs.getString(_key);
    if (raw == null) return {};
    // Degrade to empty rather than throwing through the provider build if the
    // stored blob is ever malformed (partial write, manual edit, schema drift).
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(k, (v as List).map(_parseEntry).toList()),
      );
    } catch (_) {
      return {};
    }
  }

  // Accepts both the current object form and the legacy bare-int form
  // (pre-scheme builds stored `[3000, 5173]`), treating bare ints as http.
  RecentPort _parseEntry(dynamic e) {
    if (e is int) return RecentPort(e, 'http');
    final m = e as Map<String, dynamic>;
    return RecentPort(m['port'] as int, (m['scheme'] as String?) ?? 'http');
  }

  List<RecentPort> list(String projectId) =>
      List.unmodifiable(_readAll()[projectId] ?? const <RecentPort>[]);

  /// Broadcast stream of post-write snapshots. Does NOT replay current state to
  /// late subscribers — seed from [list], then listen.
  Stream<RecentPortsChange> get changes => _changes.stream;

  /// Records [port]/[scheme] as the most-recently-used for [projectId]. An
  /// existing entry for the same port (any scheme) is replaced and moved to the
  /// front. No-ops on out-of-range ports.
  Future<void> add(String projectId, int port, String scheme) async {
    // Nothing the demo does may reach disk; its ports are canned.
    if (isDemoProjectId(projectId)) return;
    if (port < 1 || port > 65535) return;
    final all = _readAll();
    final ports = List<RecentPort>.from(all[projectId] ?? const <RecentPort>[])
      ..removeWhere((e) => e.port == port)
      ..insert(0, RecentPort(port, scheme));
    if (ports.length > _capPerProject) {
      ports.removeRange(_capPerProject, ports.length);
    }
    all[projectId] = ports;
    await _write(all, projectId, ports);
  }

  Future<void> remove(String projectId, int port) async {
    final all = _readAll();
    final existing = all[projectId];
    if (existing == null) return;
    final ports = List<RecentPort>.from(existing)
      ..removeWhere((e) => e.port == port);
    if (ports.isEmpty) {
      all.remove(projectId);
    } else {
      all[projectId] = ports;
    }
    await _write(all, projectId, ports);
  }

  /// Drops every remembered port for [projectId]. Used by project deletion so a
  /// removed project leaves no port history behind. No-ops (and emits nothing)
  /// when the project has no entries.
  Future<void> removeProject(String projectId) async {
    final all = _readAll();
    if (all.remove(projectId) == null) return;
    await _write(all, projectId, const <RecentPort>[]);
  }

  /// Drops every remembered port for every project. Used by hard sign-out —
  /// the ports were observed on machines reached under the account that is
  /// going away. Emits one empty snapshot per project that had entries so live
  /// [RecentPortsNotifier]s drop their lists too.
  Future<void> clear() async {
    final all = _readAll();
    if (all.isEmpty) return;
    await _prefs.setString(_key, jsonEncode(<String, dynamic>{}));
    if (_changes.isClosed) return;
    for (final projectId in all.keys) {
      _changes.add(RecentPortsChange(projectId, const <RecentPort>[]));
    }
  }

  Future<void> close() => _changes.close();

  Future<void> _write(
    Map<String, List<RecentPort>> all,
    String projectId,
    List<RecentPort> ports,
  ) async {
    final encoded = jsonEncode(
      all.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
    );
    // No-op write: identical blob already stored. Skip the prefs round-trip and
    // the stream emission so consumers don't rebuild on unchanged mutations
    // (mirrors RecentAgentsStore._write).
    if (_prefs.getString(_key) == encoded) return;
    await _prefs.setString(_key, encoded);
    if (!_changes.isClosed) {
      _changes.add(RecentPortsChange(projectId, List.unmodifiable(ports)));
    }
  }
}
