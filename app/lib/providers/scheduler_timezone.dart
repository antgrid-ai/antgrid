import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

/// Null means detection failed; a host timezone is not the viewer's local zone.
final schedulerLocalTimezoneProvider = FutureProvider<String?>((ref) async {
  String identifier;
  try {
    identifier = (await FlutterTimezone.getLocalTimezone()).identifier.trim();
  } catch (_) {
    return null;
  }
  if (identifier == 'UTC') return identifier;
  if (tz.timeZoneDatabase.locations.isEmpty) {
    data.initializeTimeZones();
  }
  try {
    tz.getLocation(identifier);
    return identifier;
  } on tz.LocationNotFoundException {
    return null;
  }
});
