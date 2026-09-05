/// Returns the projectId of the oldest project, or null if no project is
/// eligible for eviction. Projects with no [lastFocused] entry are treated
/// as oldest (they've never been focused).
///
/// [pinned] ids are never candidates, whatever their age. Unlike [protect]
/// (one id, the project being opened right now) a pin outlives focus: it marks
/// a project some other subsystem is still driving — a session's member
/// machine, whose transport the session bus carries frames over. Returning null
/// when every candidate is pinned is deliberate: the caller leaves the bucket
/// over cap rather than evicting a project that is still in use.
String? selectEvictionVictim({
  required List<String> open,
  required Map<String, DateTime> lastFocused,
  String? protect,
  Set<String> pinned = const {},
}) {
  String? victim;
  DateTime? victimAge;
  for (final id in open) {
    if (id == protect) continue;
    if (pinned.contains(id)) continue;
    final ts = lastFocused[id];
    if (victim == null) {
      victim = id;
      victimAge = ts;
      continue;
    }
    if (ts == null) {
      victim = id;
      victimAge = null;
      continue;
    }
    if (victimAge != null && ts.isBefore(victimAge)) {
      victim = id;
      victimAge = ts;
    }
  }
  return victim;
}
