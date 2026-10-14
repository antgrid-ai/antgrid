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
      tz.TZDateTime.from(
        instant,
        zone == 'UTC' ? tz.UTC : tz.getLocation(zone),
      ),
    );
  } on tz.LocationNotFoundException {
    return DateFormat(pattern).format(instant.toUtc());
  }
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

tz.Location _location(String zone) {
  _ensureZones();
  if (zone == 'UTC') return tz.UTC;
  try {
    return tz.getLocation(zone);
  } on tz.LocationNotFoundException {
    return tz.UTC;
  }
}

tz.TZDateTime _inZone(DateTime instant, String zone) =>
    tz.TZDateTime.from(instant, _location(zone));

/// Calendar days from [a] to [b] by wall date, so a 23h or 25h DST day still
/// counts as one.
int _dayDelta(tz.TZDateTime a, tz.TZDateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// 24-hour wall clock of [instant] in [zone]: `09:04`.
String schedulerClock(DateTime instant, String zone) =>
    DateFormat('HH:mm').format(_inZone(instant, zone));

/// The zone to name beside a time, or null when it is the viewer's own.
String? schedulerZoneNote(String scheduleZone, String viewerZone) =>
    scheduleZone == viewerZone ? null : scheduleZone;

int? _hourlyMinute(String cron) {
  final fields = cron.trim().split(RegExp(r'\s+'));
  if (fields.length != 5 || !fields.skip(1).every((f) => f == '*')) {
    return null;
  }
  final minute = int.tryParse(fields[0]);
  return minute != null && minute >= 0 && minute < 60 ? minute : null;
}

/// Primary "Repeats" line: `Every hour`, `Daily 09:00`, `Weekdays 09:00`,
/// `Custom`, `Once`.
String schedulerRepeats(AgentSchedule s) {
  final cron = s.cron;
  if (cron == null) return 'Once';
  if (_hourlyMinute(cron) != null) return 'Every hour';
  return switch (schedulerFrequency(cron)) {
    'Daily' => 'Daily ${schedulerPresetTime(cron)}',
    'Weekdays' => 'Weekdays ${schedulerPresetTime(cron)}',
    _ => 'Custom',
  };
}

/// Secondary "Repeats" line, or null when there is nothing more to say:
/// `On the hour`, `At :30`, the raw cron for Custom, the one-off's date, each
/// followed by the schedule's zone only when it differs from [viewerZone].
String? schedulerRepeatsDetail(AgentSchedule s, String viewerZone) {
  final cron = s.cron;
  final String? base;
  if (cron == null) {
    base = s.runAt == null
        ? null
        : _zonedFormat(s.runAt!, s.timezone, 'EEE d MMM');
  } else {
    final minute = _hourlyMinute(cron);
    base = minute != null
        ? (minute == 0
              ? 'On the hour'
              : 'At :${minute.toString().padLeft(2, '0')}')
        : schedulerFrequency(cron) == 'Custom'
        ? cron
        : null;
  }
  final zone = schedulerZoneNote(s.timezone, viewerZone);
  final parts = [?base, ?zone];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// `in 42m`, `in 2h 14m`, `in 3d`; past `18m ago`, `3h ago`, `2d ago`; under a
/// minute either way is `now`.
String schedulerRelative(DateTime instant, DateTime now) {
  final delta = instant.difference(now);
  final future = !delta.isNegative;
  final span = delta.abs();
  if (span.inMinutes < 1) return 'now';
  final String text;
  if (span.inHours < 1) {
    text = '${span.inMinutes}m';
  } else if (span.inHours < 24) {
    final m = span.inMinutes.remainder(60);
    text = future && m > 0 ? '${span.inHours}h ${m}m' : '${span.inHours}h';
  } else {
    text = '${span.inDays}d';
  }
  return future ? 'in $text' : '$text ago';
}

/// `Today 09:00` in [zone], `Fri 09:00` within the next 6 days, else
/// `Fri 9 Oct 09:00`. [now] is injected so callers control the clock.
String schedulerWallCompact(DateTime instant, String zone, DateTime now) {
  final at = _inZone(instant, zone);
  final days = _dayDelta(_inZone(now, zone), at);
  final clock = DateFormat('HH:mm').format(at);
  if (days == 0) return 'Today $clock';
  if (days > 0 && days <= 6) return '${DateFormat('EEE').format(at)} $clock';
  return '${DateFormat('EEE d MMM').format(at)} $clock';
}

/// Unambiguous UTC form for tooltips: `9 Oct 2026, 03:30 UTC`.
String schedulerUtcLabel(DateTime instant) =>
    '${DateFormat('d MMM y, HH:mm').format(instant.toUtc())} UTC';

/// `yyyy-MM-dd` of [instant] in [zone]; the grouping key for day headers.
String schedulerDayKey(DateTime instant, String zone) =>
    DateFormat('yyyy-MM-dd').format(_inZone(instant, zone));

/// Run-list day header: `Today · Thu 8 Oct`, `Yesterday`, else `Tue 6 Oct`.
String schedulerDayHeader(DateTime instant, String zone, DateTime now) {
  final at = _inZone(instant, zone);
  return switch (_dayDelta(at, _inZone(now, zone))) {
    0 => 'Today · ${DateFormat('EEE d MMM').format(at)}',
    1 => 'Yesterday',
    _ => DateFormat('EEE d MMM').format(at),
  };
}

/// The first midnight after [now] in [zone], as a UTC instant.
DateTime schedulerNextMidnight(DateTime now, String zone) {
  final at = _inZone(now, zone);
  final next = tz.TZDateTime(_location(zone), at.year, at.month, at.day + 1);
  return DateTime.fromMillisecondsSinceEpoch(
    next.millisecondsSinceEpoch,
    isUtc: true,
  );
}

/// Three-letter weekday of [instant] in [zone]: `Fri`.
String schedulerWeekday(DateTime instant, String zone) =>
    DateFormat('EEE').format(_inZone(instant, zone));

enum SchedulerRunTone { active, attention, success, error, muted, warning }

/// A missed trigger overrides the stored status, which only records that the
/// occurrence was never started.
String schedulerRunStatusWord(String status, {String? trigger}) {
  if (trigger == 'missed') return 'Missed';
  return switch (status) {
    'preparing' => 'Starting',
    'running' => 'Running',
    'needs-input' => 'Needs input',
    'completed' => 'Completed',
    'failed' => 'Failed',
    'interrupted' => 'Interrupted',
    'skipped' => 'Skipped',
    _ => status,
  };
}

SchedulerRunTone schedulerRunTone(String status, {String? trigger}) {
  if (trigger == 'missed') return SchedulerRunTone.warning;
  return switch (status) {
    'preparing' || 'running' => SchedulerRunTone.active,
    'needs-input' => SchedulerRunTone.attention,
    'completed' => SchedulerRunTone.success,
    'failed' => SchedulerRunTone.error,
    _ => SchedulerRunTone.muted,
  };
}

String _shortSpan(Duration d) {
  if (d.inMinutes < 1) return '<1m';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  return '${d.inDays}d';
}

/// `waiting 6m`: how long a run has been waiting since [since].
String schedulerWaiting(DateTime since, DateTime now) =>
    'waiting ${_shortSpan(now.difference(since))}';

/// Duration with a zero-padded trailing unit: `4m 02s`, `1h 05m`, `42s`.
String schedulerDurationPadded(Duration? duration) {
  if (duration == null) return '—';
  if (duration.isNegative) return '0s';
  String two(int n) => n.toString().padLeft(2, '0');
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${two(duration.inMinutes.remainder(60))}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${two(duration.inSeconds.remainder(60))}s';
  }
  return '${duration.inSeconds}s';
}

/// Line for a run still going: `Starting`, `Running · 4m 12s`,
/// `Needs input · waiting 6m`.
String schedulerActiveRunLine(ScheduleRun run, DateTime now) {
  final word = schedulerRunStatusWord(run.status);
  final since = run.startedAt ?? run.occurrenceAt;
  return switch (run.status) {
    'running' => '$word · ${schedulerDurationPadded(now.difference(since))}',
    'needs-input' => '$word · ${schedulerWaiting(since, now)}',
    _ => word,
  };
}

/// Line for a finished run: `Completed 18m ago · 1m 40s`.
String schedulerLastRunLine(ScheduleRun run, DateTime now) {
  final word = schedulerRunStatusWord(run.status, trigger: run.trigger);
  final ended = run.finishedAt ?? run.startedAt ?? run.occurrenceAt;
  final duration = run.trigger == 'missed' ? null : run.duration;
  return [
    '$word ${schedulerRelative(ended, now)}',
    if (duration != null) schedulerDurationPadded(duration),
  ].join(' · ');
}

const schedulerNoRunsYet = 'No runs yet';
const schedulerNoRunsHint = 'No runs yet. Use Run now to try a schedule.';

/// The schedule's last [limit] finished runs, oldest first, for the outcome
/// squares. Active runs are not outcomes yet.
List<ScheduleRun> schedulerRecentRuns(
  Iterable<ScheduleRun> runs,
  String scheduleId, {
  int limit = 10,
}) {
  final done =
      runs.where((r) => r.scheduleId == scheduleId && !r.active).toList()
        ..sort((a, b) => a.occurrenceAt.compareTo(b.occurrenceAt));
  return done.length <= limit ? done : done.sublist(done.length - limit);
}

/// Catch-up badge for list rows: null for the default, which stays unsaid.
String? schedulerCatchUpBadge(String catchUp) =>
    catchUp == 'skip' ? 'Skip if missed' : null;

const schedulerCatchUpOnceLabel = 'Catch up once';
const schedulerCatchUpSkipLabel = 'Skip';

class SchedulerLane {
  const SchedulerLane(this.schedule, this.dots);
  final AgentSchedule schedule;

  /// Occurrences within the horizon, soonest first.
  final List<DateTime> dots;
}

/// Lane strip data: enabled schedules with a run in the next [horizon],
/// soonest first, capped to [max] lanes with `more` counting the rest.
({List<SchedulerLane> lanes, int more}) schedulerLanes(
  Iterable<AgentSchedule> schedules,
  DateTime now, {
  Duration horizon = const Duration(hours: 24),
  int max = 6,
}) {
  final end = now.add(horizon);
  bool inWindow(DateTime t) => t.isAfter(now) && !t.isAfter(end);
  final lanes = <SchedulerLane>[];
  for (final s in schedules.where((s) => s.enabled && s.deletedAt == null)) {
    final runAt = s.runAt;
    final dots = runAt != null
        ? [
            if (s.firedAt == null && s.firedRunId == null && inWindow(runAt))
              runAt,
          ]
        : (s.upcoming.where(inWindow).toList()..sort());
    if (dots.isNotEmpty) lanes.add(SchedulerLane(s, dots));
  }
  lanes.sort((a, b) => a.dots.first.compareTo(b.dots.first));
  return (
    lanes: lanes.length <= max ? lanes : lanes.sublist(0, max),
    more: lanes.length <= max ? 0 : lanes.length - max,
  );
}
