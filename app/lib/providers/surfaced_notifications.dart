import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notification ids already surfaced, so an event arriving via both a live
/// stream and an FCM push shows once. Container-scoped, outliving the root.
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
