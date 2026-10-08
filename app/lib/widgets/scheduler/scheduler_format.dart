import '../../models/scheduler.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

void _ensureZones() {
  if (tz.timeZoneDatabase.locations.isEmpty) data.initializeTimeZones();
}

String schedulerTime(DateTime? instant, [String zone = 'UTC']) {
  if (instant == null) return '—';
  _ensureZones();
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

/// The editor's date-time text: the wall clock of [instant] in [zone].
String schedulerWallTime(DateTime instant, String zone) {
  _ensureZones();
  tz.Location location;
  try {
    location = zone == 'UTC' ? tz.UTC : tz.getLocation(zone);
  } on tz.LocationNotFoundException {
    location = tz.UTC;
  }
  return DateFormat(
    'yyyy-MM-dd HH:mm',
  ).format(tz.TZDateTime.from(instant, location));
}

/// The wire form (`yyyy-MM-ddTHH:mm`) of editor text, or null when it is not a
/// real calendar time. The bridge resolves it in the schedule's timezone.
String? schedulerWallIso(String text) {
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T]([01]\d|2[0-3]):([0-5]\d)$',
  ).firstMatch(text.trim());
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final probe = DateTime.utc(y, mo, d);
  if (probe.month != mo || probe.day != d) return null;
  return '${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}';
}

enum SchedulerOneOffState { pending, paused, pausedPassed, finished }

SchedulerOneOffState schedulerOneOffState(AgentSchedule s, DateTime now) {
  if (s.firedRunId != null || s.firedAt != null) {
    return SchedulerOneOffState.finished;
  }
  if (s.enabled) return SchedulerOneOffState.pending;
  return s.runAt!.isAfter(now)
      ? SchedulerOneOffState.paused
      : SchedulerOneOffState.pausedPassed;
}

String _zonedFormat(DateTime instant, String zone, String pattern) {
  _ensureZones();
  try {
    return DateFormat(pattern).format(
      tz.TZDateTime.from(instant, zone == 'UTC' ? tz.UTC : tz.getLocation(zone)),
    );
  } on tz.LocationNotFoundException {
    return DateFormat(pattern).format(instant.toUtc());
  }
}

/// The card's cadence line for a one-off; the finished state reports the
/// outcome of the run that consumed it instead of a time.
String schedulerOneOffSummary(
  AgentSchedule s,
  List<ScheduleRun> runs,
  DateTime now,
) {
  final at = _zonedFormat(s.runAt!, s.timezone, 'EEE d MMM, HH:mm');
  return switch (schedulerOneOffState(s, now)) {
    SchedulerOneOffState.pending => 'Once · $at',
    SchedulerOneOffState.paused => 'Paused · once at $at',
    SchedulerOneOffState.pausedPassed => 'Paused · time passed',
    SchedulerOneOffState.finished => schedulerOneOffOutcome(s, runs),
  };
}

String schedulerOneOffOutcome(AgentSchedule s, List<ScheduleRun> runs) {
  final run = runs.where((r) => r.id == s.firedRunId).firstOrNull;
  final word = run == null
      ? 'Finished'
      : run.trigger == 'missed'
      ? 'Missed'
      : switch (run.status) {
          'preparing' || 'running' => 'Running',
          'needs-input' => 'Waiting for input',
          'completed' => 'Ran',
          'failed' => 'Failed',
          'interrupted' => 'Interrupted',
          _ => 'Finished',
        };
  final firedAt = s.firedAt;
  return firedAt == null
      ? word
      : '$word · ${_zonedFormat(firedAt, s.timezone, 'd MMM, HH:mm')}';
}

/// Who made or last changed a schedule, when an agent session did.
String? schedulerProvenance(AgentSchedule s) {
  final editor = s.editedBySessionName;
  if (editor != null) return 'Edited by $editor';
  final author = s.authorSessionName ?? s.authorSessionId;
  return author == null ? null : 'Created by $author';
}

/// The draft's frequency chip for saved settings; a one-off has no cron.
String schedulerSavedFrequency(Map<String, dynamic> saved) {
  final cron = saved['cron'] as String?;
  return cron == null ? 'Once' : schedulerFrequency(cron);
}

String schedulerSavedTime(Map<String, dynamic> saved) {
  final cron = saved['cron'] as String?;
  if (cron != null) return schedulerPresetTime(cron);
  final runAt = saved['runAt'];
  return runAt is int
      ? schedulerWallTime(
          DateTime.fromMillisecondsSinceEpoch(runAt, isUtc: true),
          saved['timezone'] as String,
        )
      : runAt as String? ?? '';
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

/// Mirrors MISSED_COUNT_CAP in the bridge's scheduler models.
const schedulerMissedCountCap = 1000;

String schedulerTrigger(String trigger) => switch (trigger) {
  'cron' => 'Scheduled',
  'manual' => 'Run now',
  'missed' => 'Missed',
  'catch-up' => 'Catch-up',
  _ => trigger,
};

String schedulerMissedLabel(int? count) => switch (count) {
  null => 'Missed runs',
  1 => 'Missed 1 run',
  final n when n >= schedulerMissedCountCap =>
    'Missed $schedulerMissedCountCap+ runs',
  final n => 'Missed $n runs',
};

String schedulerCatchUpSummary(String catchUp) => catchUp == 'skip'
    ? 'Skips missed runs'
    : 'Catches up latest missed run';

String schedulerOneOffCatchUpSummary(String catchUp) => catchUp == 'skip'
    ? 'Skipped if missed'
    : 'Runs when the desktop is next open if missed';

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
