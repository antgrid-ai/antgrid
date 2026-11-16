import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../util/time_zones.dart';

/// Null means detection failed; a host timezone is not the viewer's local zone.
///
/// A legacy link name (`Asia/Calcutta`) is returned as reported, not
/// canonicalized: schedules created here carry the same name the host reports,
/// and the screen compares them by string to decide when to name a zone.
final schedulerLocalTimezoneProvider = FutureProvider<String?>((ref) async {
  String identifier;
  try {
    identifier = (await FlutterTimezone.getLocalTimezone()).identifier.trim();
  } catch (_) {
    return null;
  }
  return findTimeZone(identifier) == null ? null : identifier;
});
