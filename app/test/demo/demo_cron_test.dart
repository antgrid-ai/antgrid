import 'package:antgrid/demo/demo_cron.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

Matcher _refusal(String code, String message) => throwsA(
  isA<RpcException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.message, 'message', message),
);

Matcher _invalidCron(String message) =>
    _refusal('SCHEDULER_INVALID_CRON', message);

DateTime _utc(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0]) =>
    DateTime.utc(y, mo, d, h, mi, s);

void main() {
  final utc = demoSchedulerZone('UTC');
  final london = demoSchedulerZone('Europe/London');

  List<DateTime> next(String cron, DateTime from, {int count = 5}) =>
      DemoCron.parse(cron).after(from, utc, count: count);

  group('grammar errors', () {
    test('wrong field count', () {
      expect(
        () => DemoCron.parse('* * * *'),
        _invalidCron(
          'Cron must contain five fields (minute, hour, day, month, weekday)',
        ),
      );
      expect(
        () => DemoCron.parse('0 0 * * * *'),
        _invalidCron(
          'Cron must contain five fields (minute, hour, day, month, weekday)',
        ),
      );
    });

    test('names, question marks, zero steps and empty list items', () {
      const text =
          'Use numeric cron fields, wildcards, lists, ranges, and steps only';
      for (final bad in [
        '0 9 * * MON',
        '0 9 ? * *',
        '*/0 * * * *',
        '1,,2 * * * *',
      ]) {
        expect(() => DemoCron.parse(bad), _invalidCron(text), reason: bad);
      }
    });

    test('out of range value and range', () {
      expect(
        () => DemoCron.parse('60 * * * *'),
        _invalidCron('Constraint error, got value 60 expected range 0-59'),
      );
      expect(
        () => DemoCron.parse('0 24 * * *'),
        _invalidCron('Constraint error, got value 24 expected range 0-23'),
      );
      expect(
        () => DemoCron.parse('0 0 0 * *'),
        _invalidCron('Constraint error, got value 0 expected range 1-31'),
      );
      expect(
        () => DemoCron.parse('0 20-30 * * *'),
        _invalidCron('Constraint error, got range 20-30 expected range 0-23'),
      );
    });

    test('reversed range', () {
      expect(
        () => DemoCron.parse('30-10 * * * *'),
        _invalidCron('Invalid range: 30-10, min(30) > max(10)'),
      );
    });

    test('a day that no explicit month has', () {
      expect(
        () => DemoCron.parse('0 0 30 2 *'),
        _invalidCron('Invalid explicit day of month definition'),
      );
    });

    test('a schedule that can never fire hits the loop limit', () {
      final cron = DemoCron.parse('0 0 31 4,6 *');
      expect(
        () => cron.after(_utc(2026, 1, 1), utc),
        _invalidCron('Invalid expression, loop limit exceeded'),
      );
    });
  });

  group('timetables', () {
    test('the editor presets', () {
      final from = _utc(2026, 10, 21, 10, 7);
      expect(next('0 * * * *', from, count: 3), [
        _utc(2026, 10, 21, 11),
        _utc(2026, 10, 21, 12),
        _utc(2026, 10, 21, 13),
      ]);
      expect(next('0 9 * * *', from, count: 2), [
        _utc(2026, 10, 22, 9),
        _utc(2026, 10, 23, 9),
      ]);
      // Wed 21 Oct 2026: the next weekday runs are Thu, Fri, then Monday.
      expect(next('0 9 * * 1-5', from, count: 4), [
        _utc(2026, 10, 22, 9),
        _utc(2026, 10, 23, 9),
        _utc(2026, 10, 26, 9),
        _utc(2026, 10, 27, 9),
      ]);
    });

    test('steps, ranges with steps, and a start with a step', () {
      final from = _utc(2026, 10, 21, 10);
      expect(next('*/15 * * * *', from), [
        _utc(2026, 10, 21, 10, 15),
        _utc(2026, 10, 21, 10, 30),
        _utc(2026, 10, 21, 10, 45),
        _utc(2026, 10, 21, 11),
        _utc(2026, 10, 21, 11, 15),
      ]);
      expect(next('5-20/5 10 * * *', from), [
        _utc(2026, 10, 21, 10, 5),
        _utc(2026, 10, 21, 10, 10),
        _utc(2026, 10, 21, 10, 15),
        _utc(2026, 10, 21, 10, 20),
        _utc(2026, 10, 22, 10, 5),
      ]);
      expect(next('10/20 10 * * *', from, count: 4), [
        _utc(2026, 10, 21, 10, 10),
        _utc(2026, 10, 21, 10, 30),
        _utc(2026, 10, 21, 10, 50),
        _utc(2026, 10, 22, 10, 10),
      ]);
    });

    test('7 is Sunday, the same as 0', () {
      final from = _utc(2026, 10, 21);
      expect(
        next('0 9 * * 7', from),
        next('0 9 * * 0', from),
      );
      // 25 Oct 2026 is a Sunday.
      expect(next('0 9 * * 7', from, count: 1), [_utc(2026, 10, 25, 9)]);
    });

    test('day of month and day of week combine with OR when both restrict', () {
      // Thursday 1 Oct 2026: Fridays are 2, 9, 16; the 13th is a Tuesday.
      expect(next('0 9 13 * 5', _utc(2026, 10, 1), count: 4), [
        _utc(2026, 10, 2, 9),
        _utc(2026, 10, 9, 9),
        _utc(2026, 10, 13, 9),
        _utc(2026, 10, 16, 9),
      ]);
    });

    test('a stepped day of month still counts as restricted', () {
      // Were */2 read as a wildcard, only Mondays would fire and the 1st and
      // the 3rd (a Saturday) would be skipped.
      final days = next('0 9 */2 * 1', _utc(2026, 10, 1), count: 5);
      expect(days, [
        _utc(2026, 10, 1, 9),
        _utc(2026, 10, 3, 9),
        _utc(2026, 10, 5, 9),
        _utc(2026, 10, 7, 9),
        _utc(2026, 10, 9, 9),
      ]);
    });

    test('weekday ranges fire on weekdays only', () {
      final days = next('0 9 * * 1-5', _utc(2026, 10, 1), count: 30);
      expect(days.every((d) => d.weekday <= 5), isTrue);
    });

    test('strictly after: an exact occurrence is excluded, seconds ignored', () {
      expect(next('0 9 * * *', _utc(2026, 10, 21, 9), count: 1), [
        _utc(2026, 10, 22, 9),
      ]);
      expect(next('0 9 * * *', _utc(2026, 10, 21, 8, 59, 59), count: 1), [
        _utc(2026, 10, 21, 9),
      ]);
      expect(next('0 9 * * *', _utc(2026, 10, 21, 9, 0, 1), count: 1), [
        _utc(2026, 10, 22, 9),
      ]);
    });

    test('results are UTC instants', () {
      expect(next('0 9 * * *', _utc(2026, 10, 21)).every((d) => d.isUtc), true);
    });

    test('Feb 29 finds the next leap day', () {
      expect(next('0 0 29 2 *', _utc(2026, 10, 1), count: 1), [
        _utc(2028, 2, 29),
      ]);
    });

    test('the expression is stored with single spaces', () {
      expect(DemoCron.parse('  0   9 *  * 1-5 ').expression, '0 9 * * 1-5');
    });

    test('a wall time inside the spring-forward gap fires once', () {
      final cron = DemoCron.parse('30 1 * * *');
      final out = cron.after(_utc(2026, 3, 28, 12), london, count: 3);
      expect(out, [
        _utc(2026, 3, 29, 1, 30),
        _utc(2026, 3, 30, 0, 30),
        _utc(2026, 3, 31, 0, 30),
      ]);
    });

    test('a gap slot that shifts onto a real slot is not repeated', () {
      final cron = DemoCron.parse('0,30 1,2 * * *');
      final out = cron.after(_utc(2026, 3, 28, 12), london, count: 8);
      expect(out.toSet().length, out.length);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].isAfter(out[i - 1]), isTrue);
      }
    });
  });

  group('demoResolveRunAt', () {
    test('resolves a wall time in the zone', () {
      // BST: 09:00 in London is 08:00Z in October before the 25th.
      expect(
        demoResolveRunAt('2026-10-21T09:00', 'Europe/London'),
        _utc(2026, 10, 21, 8),
      );
      expect(
        demoResolveRunAt('2026-12-01 09:00', 'Europe/London'),
        _utc(2026, 12, 1, 9),
      );
    });

    test('an explicit offset wins over the zone', () {
      expect(
        demoResolveRunAt('2026-10-09T09:00+02:00', 'Europe/London'),
        _utc(2026, 10, 9, 7),
      );
      expect(
        demoResolveRunAt('2026-10-09T09:00Z', 'Europe/London'),
        _utc(2026, 10, 9, 9),
      );
    });

    test('refuses a time that does not exist', () {
      expect(
        () => demoResolveRunAt('2026-03-29T01:30', 'Europe/London'),
        _refusal(
          'INVALID_RUN_AT',
          '2026-03-29T01:30 does not exist in Europe/London: clocks skip '
              'forward over it. Choose a time after the change.',
        ),
      );
    });

    test('rejects a date that is not on the calendar', () {
      expect(
        () => demoResolveRunAt('2026-02-30T09:00', 'UTC'),
        _refusal(
          'INVALID_RUN_AT',
          '"2026-02-30T09:00" is not a real calendar date and time',
        ),
      );
    });

    test('rejects text that is not a date', () {
      expect(
        () => demoResolveRunAt('tomorrow', 'UTC'),
        _refusal(
          'INVALID_RUN_AT',
          '"tomorrow" is not a date and time; use a form like '
              '2026-10-09T09:00 or 2026-10-09T09:00+02:00',
        ),
      );
    });

    test('passes an epoch-millisecond int through', () {
      expect(
        demoResolveRunAt(1790000000000, 'Europe/London'),
        DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
      );
      expect(
        () => demoResolveRunAt(0, 'UTC'),
        _refusal(
          'INVALID_RUN_AT',
          'runAt must be a positive epoch-millisecond instant',
        ),
      );
    });
  });

  group('demoSchedulerZone', () {
    test('UTC maps to the UTC location', () {
      expect(demoSchedulerZone('UTC'), same(tz.UTC));
    });

    test('refuses an empty name and an offset', () {
      const text = 'Choose an IANA timezone, such as Europe/London';
      expect(() => demoSchedulerZone(''), _invalidCron(text));
      expect(() => demoSchedulerZone('+01:00'), _invalidCron(text));
    });

    test('refuses an unknown zone', () {
      expect(
        () => demoSchedulerZone('Moon/Base'),
        _invalidCron('Choose a valid IANA timezone'),
      );
    });
  });
}
