/// Formats [when] as a short relative-time string ("just now", "2 mins ago",
/// "3 weeks ago"). [now] is injectable so callers/tests are deterministic;
/// it defaults to the wall clock.
///
/// Future or sub-minute timestamps clamp to "just now" (no negative ages).
String relativeTime(DateTime when, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final d = ref.difference(when);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return _plural(d.inMinutes, 'min');
  if (d.inHours < 24) return _plural(d.inHours, 'hour');
  if (d.inDays < 7) return _plural(d.inDays, 'day');
  if (d.inDays < 30) return _plural(d.inDays ~/ 7, 'week');
  if (d.inDays < 365) return _plural(d.inDays ~/ 30, 'month');
  return _plural(d.inDays ~/ 365, 'year');
}

String _plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';

/// Local 24-hour wall-clock label (`14:05`) for same-day timestamps.
String clockTime(DateTime when) {
  final local = when.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Wall-clock label that keeps its day: `14:05` today, `Aug 3 14:05` before
/// that. [clockTime] alone is only honest on a surface read the same day — on a
/// log written while the user was away, last night's `23:40` and tonight's are
/// the same four characters.
///
/// [now] is injectable so the day boundary is deterministic in tests.
String dayAwareTime(DateTime when, {DateTime? now}) {
  final local = when.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final sameDay =
      local.year == ref.year &&
      local.month == ref.month &&
      local.day == ref.day;
  final clock = clockTime(local);
  return sameDay ? clock : '${_months[local.month - 1]} ${local.day} $clock';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Absolute wall-clock label for the on-hover tooltip: `Jul 3, 2026, 2:45 PM`
/// (local time, 12-hour clock). Hand-rolled because the app ships without
/// `intl` — see relativeTime for the coarse companion label.
String absoluteTime(DateTime when) {
  final local = when.toLocal();
  final h12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final ampm = local.hour < 12 ? 'AM' : 'PM';
  final min = local.minute.toString().padLeft(2, '0');
  return '${_months[local.month - 1]} ${local.day}, ${local.year}, '
      '$h12:$min $ampm';
}
