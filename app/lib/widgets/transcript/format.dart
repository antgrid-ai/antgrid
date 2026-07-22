/// Abbreviates a token count for compact display (e.g. `1500` -> `1.5k`).
String formatTokens(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// Compact elapsed-duration label: `1h 5m` / `2m 35s` / `45s`.
String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}
