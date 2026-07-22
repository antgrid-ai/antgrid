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

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
