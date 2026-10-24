import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

// A numeric five-field cron evaluator for the sample Scheduler. The sample has
// no bridge to ask, so this reproduces the bridge's grammar, error wording and
// day-matching rules (bridge/src/scheduler/cron.ts) closely enough that the
// editor's validation reads the same offline as it does against a machine.

const String _invalidCron = 'SCHEDULER_INVALID_CRON';
const String _invalidRunAt = 'INVALID_RUN_AT';

final RegExp _cronItem = RegExp(r'^(?:\*|\d+(?:-\d+)?)(?:\/[1-9]\d*)?$');
final RegExp _runAtText = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}(?::?\d{2})?)?$',
  caseSensitive: false,
);

// Beyond this many days without a match the expression can never fire (a
// 31st of April), and the bridge reports the same loop-limit failure.
const int _searchDays = 366 * 8;

void _ensureZones() {
  if (tz.timeZoneDatabase.locations.isEmpty) data.initializeTimeZones();
}

/// Resolves an IANA name to a location, with the bridge's two refusals.
///
/// Not `scheduler_format`'s private lookup: that one falls back to UTC for an
/// unknown zone, which is right for display and wrong for validation.
tz.Location demoSchedulerZone(String timezone) {
  if (timezone.isEmpty || timezone.startsWith('+') || timezone.startsWith('-')) {
    throw RpcException(
      _invalidCron,
      'Choose an IANA timezone, such as Europe/London',
    );
  }
  _ensureZones();
  if (timezone == 'UTC') return tz.UTC;
  try {
    return tz.getLocation(timezone);
  } on tz.LocationNotFoundException {
    throw RpcException(_invalidCron, 'Choose a valid IANA timezone');
  }
}

/// The name a zone is stored and reported under. `tz.UTC` is named `Etc/UTC`,
/// which the editor's zone field would show instead of the `UTC` it was given.
String demoZoneName(tz.Location zone) =>
    identical(zone, tz.UTC) ? 'UTC' : zone.name;

/// A parsed five-field cron expression.
class DemoCron {
  DemoCron._({
    required this.expression,
    required List<int> minutes,
    required List<int> hours,
    required Set<int> daysOfMonth,
    required Set<int> months,
    required Set<int> daysOfWeek,
    required bool domStar,
    required bool dowStar,
  }) : _minutes = minutes,
       _hours = hours,
       _daysOfMonth = daysOfMonth,
       _months = months,
       _daysOfWeek = daysOfWeek,
       _domStar = domStar,
       _dowStar = dowStar;

  /// Fields re-joined with single spaces, which is what the bridge stores.
  final String expression;
  final List<int> _minutes;
  final List<int> _hours;
  final Set<int> _daysOfMonth;
  final Set<int> _months;
  final Set<int> _daysOfWeek;
  final bool _domStar;
  final bool _dowStar;

  /// Throws [RpcException] `SCHEDULER_INVALID_CRON` with the bridge's wording.
  static DemoCron parse(String expression) {
    final fields = expression.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) {
      throw RpcException(
        _invalidCron,
        'Cron must contain five fields (minute, hour, day, month, weekday)',
      );
    }
    final wellFormed = fields.every(
      (field) => field.split(',').every(_cronItem.hasMatch),
    );
    if (!wellFormed) {
      throw RpcException(
        _invalidCron,
        'Use numeric cron fields, wildcards, lists, ranges, and steps only',
      );
    }
    final minutes = _expand(fields[0], 0, 59);
    final hours = _expand(fields[1], 0, 23);
    final daysOfMonth = _expand(fields[2], 1, 31);
    final months = _expand(fields[3], 1, 12);
    // Sunday is both 0 and 7.
    final daysOfWeek = _expand(fields[4], 0, 7).map((d) => d % 7).toSet();
    // Only a bare `*` leaves a day field unrestricted; `*/2` still restricts,
    // which decides whether the two day fields combine with OR.
    final domStar = fields[2] == '*';
    final dowStar = fields[4] == '*';
    if (RegExp(r'^\d+$').hasMatch(fields[3]) &&
        dowStar &&
        daysOfMonth.reduce((a, b) => a < b ? a : b) >
            _monthLength(months.first)) {
      throw RpcException(
        _invalidCron,
        'Invalid explicit day of month definition',
      );
    }
    return DemoCron._(
      expression: fields.join(' '),
      minutes: (minutes.toList()..sort()),
      hours: (hours.toList()..sort()),
      daysOfMonth: daysOfMonth,
      months: months,
      daysOfWeek: daysOfWeek,
      domStar: domStar,
      dowStar: dowStar,
    );
  }

  static int _monthLength(int month) => const [
    31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, //
  ][month - 1];

  static Set<int> _expand(String field, int min, int max) {
    final values = <int>{};
    for (final part in field.split(',')) {
      final slash = part.split('/');
      final base = slash[0];
      final step = slash.length > 1 ? _number(slash[1]) : 1;
      late final int start;
      late final int end;
      if (base == '*') {
        start = min;
        end = max;
      } else if (base.contains('-')) {
        final ends = base.split('-');
        start = _number(ends[0]);
        end = _number(ends[1]);
        if (start > end) {
          throw RpcException(
            _invalidCron,
            'Invalid range: $base, min($start) > max($end)',
          );
        }
        if (start < min || end > max) {
          throw RpcException(
            _invalidCron,
            'Constraint error, got range $start-$end expected range $min-$max',
          );
        }
      } else {
        start = _number(base);
        if (start < min || start > max) {
          throw RpcException(
            _invalidCron,
            'Constraint error, got value $start expected range $min-$max',
          );
        }
        // `10/20` runs from 10 to the top of the range; a bare `10` is one value.
        end = slash.length > 1 ? max : start;
      }
      for (var v = start; v <= end; v += step) {
        values.add(v);
      }
    }
    return values;
  }

  // A digit run too long for an int is far out of every range; clamping keeps
  // the refusal a constraint error instead of a FormatException.
  static int _number(String digits) => int.tryParse(digits) ?? (1 << 52);

  bool _dayMatches(DateTime day) {
    if (!_months.contains(day.month)) return false;
    final domHit = _daysOfMonth.contains(day.day);
    final dowHit = _daysOfWeek.contains(day.weekday % 7);
    if (!_domStar && !_dowStar) return domHit || dowHit;
    if (!_domStar) return domHit;
    if (!_dowStar) return dowHit;
    return true;
  }

  /// Instants strictly after [instant], ascending, minute resolution, as UTC.
  ///
  /// Throws `SCHEDULER_INVALID_CRON` when nothing fires within eight years.
  List<DateTime> after(DateTime instant, tz.Location zone, {int count = 5}) {
    final start = tz.TZDateTime.from(instant, zone);
    final floor = instant.toUtc();
    final out = <DateTime>[];
    var last = floor;
    var day = DateTime.utc(start.year, start.month, start.day);
    for (var i = 0; i < _searchDays && out.length < count; i++) {
      if (_dayMatches(day)) {
        for (final hour in _hours) {
          for (final minute in _minutes) {
            // A wall time inside a spring-forward gap shifts forward.
            final local = tz.TZDateTime(
              zone,
              day.year,
              day.month,
              day.day,
              hour,
              minute,
            );
            final utc = DateTime.fromMillisecondsSinceEpoch(
              local.millisecondsSinceEpoch,
              isUtc: true,
            );
            // Not after the previous slot means a shifted gap time landed on
            // one already accepted.
            if (!utc.isAfter(last)) continue;
            out.add(utc);
            last = utc;
            if (out.length >= count) return out;
          }
        }
      }
      day = day.add(const Duration(days: 1));
    }
    if (out.isEmpty) {
      throw RpcException(
        _invalidCron,
        'Invalid expression, loop limit exceeded',
      );
    }
    return out;
  }
}

/// An epoch-millisecond instant as is, or text read as a wall time in
/// [timezone] (or at its own UTC offset when it carries one).
DateTime demoResolveRunAt(Object? value, String timezone) {
  if (value is num) {
    final ms = value.toInt();
    if (ms <= 0 || ms != value) {
      throw RpcException(
        _invalidRunAt,
        'runAt must be a positive epoch-millisecond instant',
      );
    }
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  final shown = '$value';
  final match = value is String ? _runAtText.firstMatch(value.trim()) : null;
  if (match == null) {
    throw RpcException(
      _invalidRunAt,
      '"$shown" is not a date and time; use a form like 2026-10-09T09:00 or 2026-10-09T09:00+02:00',
    );
  }
  final text = (value as String).trim();
  final y = int.parse(match[1]!);
  final mo = int.parse(match[2]!);
  final d = int.parse(match[3]!);
  final h = int.parse(match[4]!);
  final mi = int.parse(match[5]!);
  final s = match[6] == null ? 0 : int.parse(match[6]!);
  final wall = DateTime.utc(y, mo, d, h, mi, s);
  if (wall.year != y ||
      wall.month != mo ||
      wall.day != d ||
      wall.hour != h ||
      wall.minute != mi ||
      wall.second != s) {
    throw RpcException(
      _invalidRunAt,
      '"$shown" is not a real calendar date and time',
    );
  }
  final offset = match[7];
  if (offset != null) {
    if (offset.toUpperCase() == 'Z') return wall;
    final digits = offset.substring(1).replaceFirst(':', '');
    final hours = int.parse(digits.substring(0, 2));
    final minutes = digits.length > 2 ? int.parse(digits.substring(2)) : 0;
    if (hours > 23 || minutes > 59) {
      throw RpcException(
        _invalidRunAt,
        '"$shown" has an invalid UTC offset',
      );
    }
    final sign = offset.startsWith('-') ? -1 : 1;
    return wall.subtract(Duration(minutes: sign * (hours * 60 + minutes)));
  }
  final zone = demoSchedulerZone(timezone);
  final local = tz.TZDateTime(zone, y, mo, d, h, mi, s);
  if (local.year != y ||
      local.month != mo ||
      local.day != d ||
      local.hour != h ||
      local.minute != mi) {
    throw RpcException(
      _invalidRunAt,
      '$text does not exist in $timezone: clocks skip forward over it. Choose a time after the change.',
    );
  }
  return DateTime.fromMillisecondsSinceEpoch(
    local.millisecondsSinceEpoch,
    isUtc: true,
  );
}
