import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// A machine this app has coordinates for. Admission is account trust, so this
/// is a pure COORDINATES cache — where the machine lives (`relayUrl`) and which
/// Ed25519 key to pin it against — kept so a reconnect needs neither a QR rescan
/// nor a reachable `/account/agents`. Public values only: nothing here is a
/// credential, and no private key material may ever land in SharedPreferences.
class RecentAgent {
  final String agentDeviceId;
  final String agentLabel;
  final String agentEd25519Pubkey;
  final String relayUrl;
  final DateTime pairedAt;
  final DateTime lastConnectedAt;
  final String? hostMachineName;

  const RecentAgent({
    required this.agentDeviceId,
    required this.agentLabel,
    required this.agentEd25519Pubkey,
    required this.relayUrl,
    required this.pairedAt,
    required this.lastConnectedAt,
    this.hostMachineName,
  });

  RecentAgent copyWith({DateTime? lastConnectedAt}) => RecentAgent(
    agentDeviceId: agentDeviceId,
    agentLabel: agentLabel,
    agentEd25519Pubkey: agentEd25519Pubkey,
    relayUrl: relayUrl,
    pairedAt: pairedAt,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    hostMachineName: hostMachineName,
  );

  Map<String, dynamic> toJson() => {
    'agentDeviceId': agentDeviceId,
    'agentLabel': agentLabel,
    'agentEd25519Pubkey': agentEd25519Pubkey,
    'relayUrl': relayUrl,
    'pairedAt': pairedAt.toIso8601String(),
    'lastConnectedAt': lastConnectedAt.toIso8601String(),
    'hostMachineName': hostMachineName,
  };

  factory RecentAgent.fromJson(Map<String, dynamic> j) => RecentAgent(
    agentDeviceId: j['agentDeviceId'] as String,
    agentLabel: j['agentLabel'] as String,
    agentEd25519Pubkey: j['agentEd25519Pubkey'] as String,
    relayUrl: j['relayUrl'] as String,
    pairedAt: DateTime.parse(j['pairedAt'] as String),
    lastConnectedAt: DateTime.parse(j['lastConnectedAt'] as String),
    hostMachineName: j['hostMachineName'] as String?,
  );
}

/// SharedPreferences-backed persistence for previously-paired agents. Stored
/// under a single JSON-encoded key so reads/writes are atomic per call.
///
/// The store is the single source of truth: every successful mutation emits
/// a fresh immutable snapshot on [changes], which lets Riverpod notifiers
/// stay in sync regardless of which call site wrote.
class RecentAgentsStore {
  // Bumped to v4 when the per-machine phone-key fields were retired. The new
  // fromJson ignores them, so it is the OTHER direction that needs the bump: a
  // v3 build (a branch switch on a dev machine) still requires those fields and
  // would throw on every row this build writes. A distinct key keeps the two
  // shapes from ever meeting; pre-release, so no migration (v3 precedent).
  static final _key = scopedStorageKey('antgrid.recent_agents.v4');
  final SharedPreferencesWithCache _prefs;
  final StreamController<List<RecentAgent>> _changes =
      StreamController<List<RecentAgent>>.broadcast();

  RecentAgentsStore._(this._prefs);

  static Future<RecentAgentsStore> open() async =>
      RecentAgentsStore._(await openScopedPrefs({_key}));

  List<RecentAgent> list() {
    final raw = _prefs.getString(_key);
    if (raw == null) return List.unmodifiable(const <RecentAgent>[]);
    final arr = jsonDecode(raw) as List;
    return List.unmodifiable(
      arr.map((j) => RecentAgent.fromJson(j as Map<String, dynamic>)),
    );
  }

  /// Broadcast stream of post-write snapshots. Does NOT replay the current
  /// snapshot to late subscribers — callers should seed from [list] and then
  /// listen for updates.
  Stream<List<RecentAgent>> get changes => _changes.stream;

  Future<void> upsert(RecentAgent a) async {
    final all = List<RecentAgent>.from(list());
    final i = all.indexWhere((x) => x.agentDeviceId == a.agentDeviceId);
    if (i >= 0) {
      all[i] = a;
    } else {
      all.add(a);
    }
    await _write(all);
  }

  Future<void> remove(String agentDeviceId) async {
    final all = list().where((x) => x.agentDeviceId != agentDeviceId).toList();
    await _write(all);
  }

  /// Drops every remembered agent. Used by hard sign-out — the account these
  /// coordinates were reachable under is gone, so the rows are dead.
  Future<void> clear() => _write(const <RecentAgent>[]);

  /// Closes the change stream. Production callers normally let the store
  /// live for the app's lifetime; tests close it to avoid pending-timer
  /// warnings.
  Future<void> close() => _changes.close();

  Future<void> _write(List<RecentAgent> all) async {
    final encoded = jsonEncode(all.map((x) => x.toJson()).toList());
    // No-op write: same encoded blob as what's already stored. Skip both the
    // prefs round-trip and the stream emission so consumers don't see a
    // spurious rebuild on unchanged upserts.
    if (_prefs.getString(_key) == encoded) return;
    await _prefs.setString(_key, encoded);
    if (!_changes.isClosed) {
      _changes.add(List.unmodifiable(all));
    }
  }
}
