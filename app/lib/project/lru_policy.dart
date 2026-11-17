/// Returns the projectId of the oldest project, or null if no project is
/// eligible for eviction. Projects with no [lastFocused] entry are treated
/// as oldest (they've never been focused).
String? selectEvictionVictim({
  required List<String> open,
  required Map<String, DateTime> lastFocused,
  String? protect,
}) {
  String? victim;
  DateTime? victimAge;
  for (final id in open) {
    if (id == protect) continue;
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
