import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

String schedulerTime(DateTime? instant, [String zone = 'UTC']) {
  if (instant == null) return '—';
  if (tz.timeZoneDatabase.locations.isEmpty) {
    data.initializeTimeZones();
  }
  try {
    final local = tz.TZDateTime.from(
      instant,
      zone == 'UTC' ? tz.UTC : tz.getLocation(zone),
    );
    return '${DateFormat('d MMM y, HH:mm').format(local)} · $zone (${local.timeZoneName})';
  } on tz.LocationNotFoundException {
    return '${DateFormat('d MMM y, HH:mm').format(instant.toUtc())} · UTC (unknown zone: $zone)';
  }
}

String schedulerLocalTime(DateTime? instant, String? zone) {
  if (zone != null) return schedulerTime(instant, zone);
  if (instant == null) return '—';
  final local = instant.toLocal();
  return '${DateFormat('d MMM y, HH:mm').format(local)} · Local time (${local.timeZoneName})';
}

String schedulerFrequency(String cron) {
  final fields = cron.trim().split(RegExp(r'\s+'));
  if (fields.length == 5 &&
      fields[0] == '0' &&
      fields.skip(1).every((f) => f == '*')) {
    return 'Hourly';
  }
  if (fields.length == 5 &&
      fields[2] == '*' &&
      fields[3] == '*' &&
      (fields[4] == '*' || fields[4] == '1-5')) {
    final minute = int.tryParse(fields[0]);
    final hour = int.tryParse(fields[1]);
    if (minute != null &&
        minute >= 0 &&
        minute < 60 &&
        hour != null &&
        hour >= 0 &&
        hour < 24) {
      return fields[4] == '*' ? 'Daily' : 'Weekdays';
    }
  }
  return 'Custom';
}

String schedulerPresetTime(String cron) {
  final fields = cron.trim().split(RegExp(r'\s+'));
  if (schedulerFrequency(cron) case 'Daily' || 'Weekdays') {
    return '${fields[1].padLeft(2, '0')}:${fields[0].padLeft(2, '0')}';
  }
  return '09:00';
}

String? schedulerPresetCron(String frequency, String time) {
  if (frequency == 'Hourly') return '0 * * * *';
  final match = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(time);
  if (match == null) return null;
  return '${int.parse(match[2]!)} ${int.parse(match[1]!)} * * ${frequency == 'Weekdays' ? '1-5' : '*'}';
}

String schedulerCadence(String cron, String zone) {
  final frequency = schedulerFrequency(cron);
  final description = switch (frequency) {
    'Daily' || 'Weekdays' => '$frequency at ${schedulerPresetTime(cron)}',
    'Hourly' => 'Hourly at minute 00',
    _ => cron,
  };
  return '$description · $zone';
}

String schedulerDuration(Duration? duration) {
  if (duration == null) return '—';
  if (duration.isNegative) return '0s';
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
  return '${duration.inSeconds}s';
}
