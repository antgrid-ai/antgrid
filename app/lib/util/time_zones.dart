import 'package:timezone/data/latest_all.dart' as data;
import 'package:timezone/timezone.dart' as tz;

/// Loads the IANA database once, backward links included.
///
/// Hosts and phones report legacy link names such as `Asia/Calcutta` (Windows'
/// ICU still does), and only the `_all` variant carries those links; the
/// default `latest` set drops them, which left every conversion silently in
/// UTC under a label naming the machine's zone. Whichever database loads first
/// wins, so the sentinel also replaces a link-less set some other import may
/// have loaded. Load through here, never through `latest.dart` directly.
void ensureTimeZones() {
  if (tz.timeZoneDatabase.locations.containsKey('Asia/Calcutta')) return;
  data.initializeTimeZones();
}

/// The location for an IANA [name], or null when this database has no such
/// zone. `UTC` is answered without the database, matching what the bridge
/// accepts.
tz.Location? findTimeZone(String name) {
  if (name == 'UTC') return tz.UTC;
  ensureTimeZones();
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    return null;
  }
}
