import 'package:antgrid/models/scheduler.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
import 'package:flutter_test/flutter_test.dart';

AgentSchedule _schedule({
  String id = 's1',
  String? cron = '0 9 * * *',
  DateTime? runAt,
  String timezone = 'Asia/Kolkata',
  bool enabled = true,
  List<DateTime> upcoming = const [],
  DateTime? firedAt,
}) => AgentSchedule(
  id: id,
  name: 'n',
  projectId: 'p',
  agentId: 'claude',
  mode: 'chat',
  prompt: 'x',
  approvalPolicy: 'normal',
  workspace: 'shared',
  cron: runAt == null ? cron : null,
  runAt: runAt,
  timezone: timezone,
  enabled: enabled,
  upcoming: upcoming,
  firedAt: firedAt,
);

ScheduleRun _run(
  String status, {
  String id = 'r',
  String scheduleId = 's1',
  String trigger = 'cron',
  required DateTime at,
  DateTime? started,
  DateTime? finished,
}) => ScheduleRun(
  id: id,
  scheduleId: scheduleId,
  projectId: 'p',
  status: status,
  trigger: trigger,
  occurrenceAt: at,
  startedAt: started,
  finishedAt: finished,
);

void main() {
  // Thu 8 Oct 2026 12:00 UTC = 17:30 in Kolkata, 13:00 in London (BST).
  final now = DateTime.utc(2026, 10, 8, 12);

  group('AgentSchedule.upcoming', () {
    Map<String, dynamic> json([Object? upcoming]) => {
      'id': 's',
      'name': 'n',
      'projectId': 'p',
      'agentId': 'a',
      'mode': 'chat',
      'prompt': 'x',
      'approvalPolicy': 'normal',
      'workspace': 'shared',
      'timezone': 'UTC',
      'enabled': true,
      'upcoming': ?upcoming,
    };

    test('parses epoch milliseconds', () {
      final s = AgentSchedule.fromJson(json([1000, 2000]));
      expect(s.upcoming, [
        DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
      ]);
    });

    test('defaults to empty', () {
      expect(AgentSchedule.fromJson(json()).upcoming, isEmpty);
    });
  });

  group('repeats', () {
    test('primary line', () {
      expect(schedulerRepeats(_schedule(cron: '0 * * * *')), 'Every hour');
      expect(schedulerRepeats(_schedule(cron: '30 * * * *')), 'Every hour');
      expect(schedulerRepeats(_schedule(cron: '0 9 * * *')), 'Daily 09:00');
      expect(
        schedulerRepeats(_schedule(cron: '5 18 * * 1-5')),
        'Weekdays 18:05',
      );
      expect(schedulerRepeats(_schedule(cron: '*/7 * * * *')), 'Custom');
      expect(schedulerRepeats(_schedule(runAt: now)), 'Once');
    });

    test('detail line', () {
      expect(
        schedulerRepeatsDetail(_schedule(cron: '0 * * * *'), 'Asia/Kolkata'),
        'On the hour',
      );
      expect(
        schedulerRepeatsDetail(_schedule(cron: '30 * * * *'), 'Asia/Kolkata'),
        'At :30',
      );
      expect(
        schedulerRepeatsDetail(_schedule(cron: '0 9 * * *'), 'Asia/Kolkata'),
        isNull,
      );
      expect(
        schedulerRepeatsDetail(
          _schedule(cron: '0 9 * * *', timezone: 'Europe/London'),
          'Asia/Kolkata',
        ),
        'Europe/London',
      );
      expect(
        schedulerRepeatsDetail(_schedule(cron: '*/7 * * * *'), 'Asia/Kolkata'),
        '*/7 * * * *',
      );
      expect(
        schedulerRepeatsDetail(
          _schedule(runAt: DateTime.utc(2026, 10, 9, 8)),
          'Asia/Kolkata',
        ),
        'Fri 9 Oct',
      );
    });

    test('zone note only when different', () {
      expect(schedulerZoneNote('UTC', 'UTC'), isNull);
      expect(schedulerZoneNote('Europe/London', 'UTC'), 'Europe/London');
    });
  });

  group('schedulerRelative', () {
    test('future', () {
      expect(
        schedulerRelative(now.add(const Duration(seconds: 20)), now),
        'now',
      );
      expect(
        schedulerRelative(now.add(const Duration(minutes: 42)), now),
        'in 42m',
      );
      expect(
        schedulerRelative(now.add(const Duration(hours: 2, minutes: 14)), now),
        'in 2h 14m',
      );
      expect(
        schedulerRelative(now.add(const Duration(hours: 2)), now),
        'in 2h',
      );
      expect(
        schedulerRelative(now.add(const Duration(days: 3, hours: 5)), now),
        'in 3d',
      );
    });

    test('past', () {
      expect(
        schedulerRelative(now.subtract(const Duration(minutes: 18)), now),
        '18m ago',
      );
      expect(
        schedulerRelative(
          now.subtract(const Duration(hours: 3, minutes: 20)),
          now,
        ),
        '3h ago',
      );
      expect(
        schedulerRelative(now.subtract(const Duration(days: 2)), now),
        '2d ago',
      );
    });
  });

  group('schedulerWallCompact', () {
    test('today, this week, later', () {
      expect(
        schedulerWallCompact(
          DateTime.utc(2026, 10, 8, 18),
          'Asia/Kolkata',
          now,
        ),
        'Today 23:30',
      );
      expect(
        schedulerWallCompact(
          DateTime.utc(2026, 10, 9, 3, 30),
          'Asia/Kolkata',
          now,
        ),
        'Fri 09:00',
      );
      expect(
        schedulerWallCompact(
          DateTime.utc(2026, 10, 14, 3, 30),
          'Asia/Kolkata',
          now,
        ),
        'Wed 09:00',
      );
      expect(
        schedulerWallCompact(
          DateTime.utc(2026, 10, 15, 3, 30),
          'Asia/Kolkata',
          now,
        ),
        'Thu 15 Oct 09:00',
      );
    });

    test('day boundary follows the zone, not UTC', () {
      // 20:00 UTC on the 8th is already 01:30 on the 9th in Kolkata.
      expect(
        schedulerWallCompact(
          DateTime.utc(2026, 10, 8, 20),
          'Asia/Kolkata',
          now,
        ),
        'Fri 01:30',
      );
    });

    test('past instants use the date', () {
      expect(
        schedulerWallCompact(DateTime.utc(2026, 10, 6, 12), 'UTC', now),
        'Tue 6 Oct 12:00',
      );
    });

    test('DST: day count survives a 25h day', () {
      // London leaves BST on Sun 25 Oct 2026.
      final sat = DateTime.utc(2026, 10, 24, 12);
      expect(
        schedulerWallCompact(
          DateTime.utc(2026, 10, 25, 12),
          'Europe/London',
          sat,
        ),
        'Sun 12:00',
      );
    });
  });

  test('schedulerUtcLabel', () {
    expect(
      schedulerUtcLabel(DateTime.utc(2026, 10, 9, 3, 30)),
      '9 Oct 2026, 03:30 UTC',
    );
  });

  test('schedulerClock is 24-hour in the zone', () {
    expect(
      schedulerClock(DateTime.utc(2026, 10, 8, 3, 34), 'Asia/Kolkata'),
      '09:04',
    );
    expect(schedulerClock(DateTime.utc(2026, 10, 8, 21), 'UTC'), '21:00');
  });

  group('day headers', () {
    test('today, yesterday, older', () {
      expect(schedulerDayHeader(now, 'UTC', now), 'Today · Thu 8 Oct');
      expect(
        schedulerDayHeader(DateTime.utc(2026, 10, 7, 23), 'UTC', now),
        'Yesterday',
      );
      expect(
        schedulerDayHeader(DateTime.utc(2026, 10, 6, 9), 'UTC', now),
        'Tue 6 Oct',
      );
    });

    test('grouping honours the zone', () {
      // 20:00 UTC on the 7th is already the 8th in Kolkata.
      final late = DateTime.utc(2026, 10, 7, 20);
      expect(
        schedulerDayHeader(late, 'Asia/Kolkata', now),
        'Today · Thu 8 Oct',
      );
      expect(schedulerDayKey(late, 'Asia/Kolkata'), '2026-10-08');
      expect(schedulerDayKey(late, 'UTC'), '2026-10-07');
    });
  });

  group('schedulerNextMidnight', () {
    test('is the zone midnight', () {
      expect(
        schedulerNextMidnight(now, 'Asia/Kolkata'),
        DateTime.utc(2026, 10, 8, 18, 30),
      );
      expect(schedulerNextMidnight(now, 'UTC'), DateTime.utc(2026, 10, 9));
    });

    test('spans a DST change', () {
      // New York leaves EDT on Sun 1 Nov 2026: midnight Sat->Sun is EDT, so
      // the next midnight after Sun 00:30 EST/EDT is 05:00 UTC (EST).
      expect(
        schedulerNextMidnight(
          DateTime.utc(2026, 11, 1, 4, 30),
          'America/New_York',
        ),
        DateTime.utc(2026, 11, 2, 5),
      );
    });

    test('weekday label', () {
      expect(
        schedulerWeekday(DateTime.utc(2026, 10, 8, 18, 30), 'Asia/Kolkata'),
        'Fri',
      );
    });
  });

  group('run status', () {
    test('words', () {
      expect(schedulerRunStatusWord('preparing'), 'Starting');
      expect(schedulerRunStatusWord('running'), 'Running');
      expect(schedulerRunStatusWord('needs-input'), 'Needs input');
      expect(schedulerRunStatusWord('completed'), 'Completed');
      expect(schedulerRunStatusWord('failed'), 'Failed');
      expect(schedulerRunStatusWord('interrupted'), 'Interrupted');
      expect(schedulerRunStatusWord('skipped'), 'Skipped');
      expect(schedulerRunStatusWord('skipped', trigger: 'missed'), 'Missed');
    });

    test('tones', () {
      expect(schedulerRunTone('running'), SchedulerRunTone.active);
      expect(schedulerRunTone('needs-input'), SchedulerRunTone.attention);
      expect(schedulerRunTone('completed'), SchedulerRunTone.success);
      expect(schedulerRunTone('failed'), SchedulerRunTone.error);
      expect(schedulerRunTone('interrupted'), SchedulerRunTone.muted);
      expect(schedulerRunTone('skipped'), SchedulerRunTone.muted);
      expect(
        schedulerRunTone('skipped', trigger: 'missed'),
        SchedulerRunTone.warning,
      );
    });
  });

  test('schedulerWaiting', () {
    expect(
      schedulerWaiting(now.subtract(const Duration(minutes: 6)), now),
      'waiting 6m',
    );
    expect(
      schedulerWaiting(now.subtract(const Duration(seconds: 10)), now),
      'waiting <1m',
    );
    expect(
      schedulerWaiting(now.subtract(const Duration(hours: 2, minutes: 5)), now),
      'waiting 2h 5m',
    );
  });

  test('schedulerDurationPadded', () {
    expect(schedulerDurationPadded(null), '—');
    expect(schedulerDurationPadded(const Duration(seconds: 42)), '42s');
    expect(schedulerDurationPadded(const Duration(seconds: 242)), '4m 02s');
    expect(schedulerDurationPadded(const Duration(minutes: 65)), '1h 05m');
    expect(schedulerDurationPadded(const Duration(seconds: -3)), '0s');
  });

  group('run lines', () {
    test('active', () {
      final start = now.subtract(const Duration(minutes: 4, seconds: 12));
      expect(
        schedulerActiveRunLine(_run('running', at: start, started: start), now),
        'Running · 4m 12s',
      );
      final wait = now.subtract(const Duration(minutes: 6));
      expect(
        schedulerActiveRunLine(
          _run('needs-input', at: wait, started: wait),
          now,
        ),
        'Needs input · waiting 6m',
      );
      expect(
        schedulerActiveRunLine(_run('preparing', at: now), now),
        'Starting',
      );
    });

    test('last run', () {
      final start = now.subtract(const Duration(minutes: 20));
      final end = start.add(const Duration(minutes: 1, seconds: 40));
      expect(
        schedulerLastRunLine(
          _run('completed', at: start, started: start, finished: end),
          now,
        ),
        'Completed 18m ago · 1m 40s',
      );
      expect(
        schedulerLastRunLine(
          _run(
            'skipped',
            trigger: 'missed',
            at: now.subtract(const Duration(hours: 3)),
          ),
          now,
        ),
        'Missed 3h ago',
      );
    });
  });

  test('schedulerRecentRuns keeps the last terminal runs, oldest first', () {
    final runs = [
      for (var i = 0; i < 12; i++)
        _run(
          'completed',
          id: 'r$i',
          at: now.subtract(Duration(hours: 12 - i)),
        ),
      _run('running', id: 'live', at: now),
      _run('failed', id: 'other', scheduleId: 's2', at: now),
    ];
    final recent = schedulerRecentRuns(runs.reversed, 's1');
    expect(recent.map((r) => r.id), [for (var i = 2; i < 12; i++) 'r$i']);
  });

  test('catch-up copy', () {
    expect(schedulerCatchUpBadge('latest'), isNull);
    expect(schedulerCatchUpBadge('skip'), 'Skip if missed');
  });

  group('schedulerLanes', () {
    DateTime h(int n) => now.add(Duration(hours: n));

    test('keeps enabled schedules with runs in 24h, soonest first', () {
      final a = _schedule(id: 'a', upcoming: [h(5), h(6), h(30)]);
      final b = _schedule(id: 'b', upcoming: [h(1)]);
      final paused = _schedule(id: 'p', enabled: false, upcoming: [h(2)]);
      final none = _schedule(id: 'n', upcoming: [h(30)]);
      final r = schedulerLanes([a, b, paused, none], now);
      expect(r.lanes.map((l) => l.schedule.id), ['b', 'a']);
      expect(r.lanes.last.dots, [h(5), h(6)]);
      expect(r.more, 0);
    });

    test('one-off inside the window, not once fired', () {
      final inside = _schedule(id: 'o', runAt: h(3));
      final outside = _schedule(id: 'x', runAt: h(40));
      final fired = _schedule(id: 'f', runAt: h(3), firedAt: now);
      final r = schedulerLanes([inside, outside, fired], now);
      expect(r.lanes.map((l) => l.schedule.id), ['o']);
    });

    test('caps lanes and counts the rest', () {
      final all = [
        for (var i = 0; i < 8; i++) _schedule(id: 's$i', upcoming: [h(i + 1)]),
      ];
      final r = schedulerLanes(all.reversed, now);
      expect(r.lanes.length, 6);
      expect(r.lanes.first.schedule.id, 's0');
      expect(r.more, 2);
    });
  });
}
