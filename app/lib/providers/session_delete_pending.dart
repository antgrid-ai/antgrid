import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../services/session_delete_policy.dart';

/// Key for one in-flight delete: a session id alone is not unique, because the
/// same id can exist under two drawer entries.
String sessionDeleteKey(String entryId, String sessionId) =>
    '$entryId/$sessionId';

/// App-local marks for deletes the app has asked for and not yet seen answered.
///
/// Strictly SUBORDINATE to `SessionEntry.deleting`, which is the authoritative
/// signal. This exists for the one surface the wire flag cannot reach: a remote
/// Recents delete goes over the control plane, whose session lists are polled
/// `sessions.list` peeks and are never pushed, so no `deleting` frame ever
/// arrives there.
///
/// Rendering only. It must never drive selection: it is armed on the confirm,
/// and the bridge can still refuse the delete at its preflight afterwards.
final sessionDeleteRequestsProvider =
    NotifierProvider<SessionDeleteRequests, Set<String>>(
      SessionDeleteRequests.new,
    );

class SessionDeleteRequests extends Notifier<Set<String>> {
  final Map<String, Timer> _expiry = {};

  @override
  Set<String> build() {
    ref.onDispose(() {
      for (final t in _expiry.values) {
        t.cancel();
      }
      _expiry.clear();
    });
    return const {};
  }

  /// Mark [key] in flight. Auto-expires at a generous ceiling so a row that
  /// outlives every disarm path — its surface unmounted mid-delete, the machine
  /// gone — cannot stay pending forever.
  void arm(String key) {
    _expiry.remove(key)?.cancel();
    _expiry[key] = Timer(kSessionDeleteAckTimeout * 2, () => disarm(key));
    if (state.contains(key)) return;
    state = {...state, key};
  }

  void disarm(String key) {
    _expiry.remove(key)?.cancel();
    if (!state.contains(key)) return;
    state = {...state}..remove(key);
  }
}

/// Whether [session] should render as being deleted — the wire flag OR this
/// app's own mark. The single OR site, so no row re-derives it.
bool sessionDeleteInFlight(
  WidgetRef ref,
  String entryId,
  SessionEntry session,
) {
  if (session.deleting) return true;
  return ref.watch(
    sessionDeleteRequestsProvider.select(
      (s) => s.contains(sessionDeleteKey(entryId, session.id)),
    ),
  );
}
