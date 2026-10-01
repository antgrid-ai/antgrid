import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Logical notification ids already surfaced (toast or OS notification), so
/// each event is shown at most once REGARDLESS of arrival surface.
///
/// The same event can arrive twice — once via a live provider stream
/// (foreground) and once via an FCM push (the bridge seals
/// `sourceMessageId === escalationId` for escalations and `=== msg.id` for
/// agent notifications, see push-dispatcher.ts) — so one set keyed on the
/// stable id is what prevents the double toast/notification.
/// `handlerEscalationsProvider` re-seeds pending escalations on every rebuild
/// to close the broadcast-subscribe race; this set is what makes that re-seed
/// idempotent.
///
/// Container-scoped rather than held by `AgentNotificationSurfacer`, which
/// reads it: the root screen it wraps is replaced around sign-in and demo mode,
/// and a set that died with it would let the next re-seed announce every
/// pending escalation again.
///
/// NOT shared across isolates, so a background push followed by a foreground
/// replay of the same id on reopen is a known v1 gap (see
/// push_background_handler.dart).
class SurfacedNotificationIds {
  /// Dedup only needs recent ids; re-seeing one evicted long ago risks at most
  /// one duplicate — fine for best-effort notifications.
  static const _cap = 512;

  /// Insertion-ordered (a `LinkedHashSet`), so `.first` is the oldest.
  final Set<String> _ids = <String>{};

  /// Record [id] as surfaced. False if it already was — a duplicate to
  /// suppress.
  bool mark(String id) {
    if (!_ids.add(id)) return false;
    if (_ids.length > _cap) _ids.remove(_ids.first);
    return true;
  }
}

final surfacedNotificationIdsProvider = Provider<SurfacedNotificationIds>(
  (ref) => SurfacedNotificationIds(),
  name: 'surfacedNotificationIds',
);
