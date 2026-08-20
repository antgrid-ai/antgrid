import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sessions.dart';
import 'value_controller.dart';

/// A mode flip the bridge has not acknowledged yet.
///
/// `session:set-mode` waits out the old runtime's teardown before it replies,
/// and the resumed agent then takes a beat to repaint, so `SessionEntry.mode`
/// lags the tap by seconds. Held app-wide rather than in the toggle's State
/// because the agent panel swaps to the target view off the same value —
/// holding the old view up until the new one has content reads as an ignored
/// tap.
class PendingSessionMode {
  const PendingSessionMode({required this.sessionId, required this.mode});

  final String sessionId;
  final String mode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingSessionMode &&
          other.sessionId == sessionId &&
          other.mode == mode;

  @override
  int get hashCode => Object.hash(sessionId, mode);
}

final pendingSessionModeProvider =
    NotifierProvider<ValueController<PendingSessionMode?>, PendingSessionMode?>(
      () => ValueController(null),
    );

/// The mode the workspace should render for the focused session: the in-flight
/// target while a flip is pending, else the acked entry value. Null when no
/// session is focused.
final activeSessionModeProvider = Provider<String?>((ref) {
  // Cache-backed: a session's mode is fixed until a flip acks, and null here is
  // read downstream as "not chat" — which rendered the terminal view for a chat
  // session every time the live row was still re-resolving.
  final active = ref.watch(activeSessionOrCachedProvider);
  if (active == null) return null;
  final pending = ref.watch(pendingSessionModeProvider);
  return pending != null && pending.sessionId == active.id
      ? pending.mode
      : active.mode;
});
