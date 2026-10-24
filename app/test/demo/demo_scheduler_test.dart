import 'dart:convert';

import 'package:antgrid/demo/demo_cron.dart';
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/demo_scheduler.dart';
import 'package:antgrid/demo/fixtures/demo_scheduler_fixtures.dart';
import 'package:antgrid/demo/fixtures/demo_workspace_fixtures.dart';
import 'package:antgrid/models/scheduler.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter_test/flutter_test.dart';

typedef _Json = Map<String, dynamic>;

Matcher _refusal(String code, [String? message]) {
  var m = isA<RpcException>().having((e) => e.code, 'code', code);
  if (message != null) m = m.having((e) => e.message, 'message', message);
  return throwsA(m);
}

void main() {
  final london = demoSchedulerZone('Europe/London');
  late DateTime t;
  late DemoSchedulerBackend backend;

  DemoSchedulerBackend backendAt(DateTime at) => DemoSchedulerBackend(
    now: () => at,
    localTimezone: () async => 'Europe/London',
  );

  setUp(() {
    // 11:07 in London: BST runs until the 25th.
    t = DateTime.utc(2026, 10, 21, 10, 7);
    backend = DemoSchedulerBackend(
      now: () => t,
      localTimezone: () async => 'Europe/London',
    );
  });

  Future<_Json> rq(String method, [_Json params = const {}]) =>
      backend.request(method, params);

  List<_Json> maps(Object? raw) => (raw as List).cast<_Json>();

  Future<_Json> list() => rq('scheduler.list');

  Future<List<_Json>> rows() async {
    final l = await list();
    return [...maps(l['schedules']), ...maps(l['oneOffSchedules'])];
  }

  Future<_Json> row(String id) async =>
      (await rows()).firstWhere((r) => r['id'] == id);

  Future<List<ScheduleRun>> runsOf([String? scheduleId]) async {
    final r = await rq('scheduler.runs', {
      'scheduleId': ?scheduleId,
    });
    return maps(r['runs']).map(ScheduleRun.fromJson).toList();
  }

  int ms(DateTime d) => d.millisecondsSinceEpoch;

  _Json newSchedule({
    String name = 'Review open PRs',
    String mode = 'terminal',
    String workspace = 'shared',
    String? cron = '0 9 * * *',
    Object? runAt,
    Map<String, Object?> extra = const {},
  }) => {
    'name': name,
    'prompt': 'Look over the open pull requests and summarise them.',
    'projectId': kDemoProjectId,
    'agentId': 'claude-code',
    'mode': mode,
    'approvalPolicy': 'default',
    'workspace': workspace,
    'cron': ?(runAt == null ? cron : null),
    'runAt': ?runAt,
    'timezone': 'Europe/London',
    'catchUp': 'latest',
    'enabled': true,
    ...extra,
  };

  Future<_Json> create(_Json schedule) async =>
      ((await rq('scheduler.create', {'schedule': schedule}))['schedule']
              as Map)
          .cast<String, dynamic>();

  test('capabilities never carry an error and describe the sample agents', () async {
    final c = await rq('scheduler.capabilities');
    expect(c.containsKey('error'), isFalse);
    expect(c['supported'], isTrue);
    expect(c['timezone'], 'Europe/London');
    expect(c['supportsOneOff'], isTrue);
    expect(c['supportsCatchUp'], isTrue);
    expect(c['supportsBaseBranchClear'], isTrue);
    final parsed = SchedulerCapabilities.fromJson(c);
    expect(parsed.agents.map((a) => a.agentId), ['claude-code', 'codex']);
    for (final a in parsed.agents) {
      expect(a.modes, ['terminal', 'chat']);
    }
    expect(parsed.chatModes['claude-code']!.map((m) => m.id), [
      'default',
      'auto',
      'acceptEdits',
      'plan',
    ]);
    expect(parsed.chatModes['claude-code']!.every((m) => m.name.isNotEmpty), true);
  });

  test('the zone falls back to UTC when the device zone is unknown', () async {
    final utc = DemoSchedulerBackend(
      now: () => t,
      localTimezone: () async => 'Not/AZone',
    );
    expect((await utc.request('scheduler.capabilities'))['timezone'], 'UTC');
    final failing = DemoSchedulerBackend(
      now: () => t,
      localTimezone: () async => throw StateError('no channel'),
    );
    expect((await failing.request('scheduler.capabilities'))['timezone'], 'UTC');
    final none = DemoSchedulerBackend(now: () => t);
    expect((await none.request('scheduler.capabilities'))['timezone'], 'UTC');
  });

  group('seed', () {
    test('nothing is active and nothing is red', () async {
      final runs = await runsOf();
      expect(runs, isNotEmpty);
      expect(runs.where((r) => r.active), isEmpty);
      expect(runs.every((r) => r.status == 'completed'), isTrue);
      expect(
        runs.where((r) => const {'failed', 'missed', 'skipped'}.contains(r.status)),
        isEmpty,
      );
      expect(runs.every((r) => r.projectId == kDemoProjectId), isTrue);
      expect(runs.every((r) => r.scheduleName != null), isTrue);
      expect(
        runs.every(
          (r) =>
              r.sessionId == kDemoSessionCartId ||
              r.sessionId == kDemoSessionCheckoutId,
        ),
        isTrue,
      );
    });

    test('the five schedules, with their states', () async {
      final all = {for (final r in await rows()) r['id'] as String: r};
      expect(all.keys, [
        kDemoScheduleNightlyId,
        kDemoScheduleSmokeId,
        kDemoScheduleDepsId,
        kDemoScheduleReleaseNotesId,
        kDemoScheduleTagId,
      ]);
      expect(all[kDemoScheduleNightlyId]!['name'], kDemoScheduleNightlyName);
      expect(all[kDemoScheduleDepsId]!['enabled'], isFalse);
      expect(all[kDemoScheduleDepsId]!['catchUp'], 'skip');
      expect(all[kDemoScheduleNightlyId]!['checkoutId'], 'nightly-test-run');
      expect(all[kDemoScheduleNightlyId]!['chatMode'], 'acceptEdits');
      expect(all[kDemoScheduleReleaseNotesId]!['workspaceCreated'], isFalse);
      expect(all[kDemoScheduleReleaseNotesId]!['chatMode'], 'plan');
      for (final r in all.values) {
        expect(r['timezone'], 'Europe/London');
        expect(r.containsKey('authorDeviceId'), isFalse);
      }
    });

    test('every enabled cron row waits for the first occurrence after now', () async {
      final l = await list();
      for (final r in maps(l['schedules']).where((r) => r['enabled'] == true)) {
        final expected = DemoCron.parse(
          r['cron'] as String,
        ).after(t, london, count: 1).first;
        expect(r['nextOccurrence'], ms(expected), reason: '${r['id']}');
        expect(r['nextOccurrence'] as int, greaterThan(ms(t)));
      }
    });

    test('the finished one-off points at a completed run', () async {
      final tag = await row(kDemoScheduleTagId);
      expect(tag['firedRunId'], kDemoTagReleaseRunId);
      final run = (await runsOf()).firstWhere((r) => r.id == kDemoTagReleaseRunId);
      expect(run.status, 'completed');
      expect(run.scheduleId, kDemoScheduleTagId);
      final parsed = AgentSchedule.fromJson(tag);
      expect(
        schedulerOneOffState(parsed, t),
        SchedulerOneOffState.finished,
      );
      expect(schedulerOneOffOutcome(parsed, await runsOf()), startsWith('Ran'));
    });

    test('the pending one-off is in the future and on the hour', () async {
      final pending = AgentSchedule.fromJson(
        await row(kDemoScheduleReleaseNotesId),
      );
      expect(pending.runAt!.isAfter(t.add(const Duration(hours: 2))), isTrue);
      expect(pending.runAt!.minute, 0);
      expect(schedulerOneOffState(pending, t), SchedulerOneOffState.pending);
    });

    test('is quiet at any minute of entry', () async {
      final anchors = [
        DateTime.utc(2026, 10, 21, 10, 0, 30),
        DateTime.utc(2026, 10, 21, 10, 1, 0),
        DateTime.utc(2026, 10, 21, 10, 1, 50),
        // 02:03 in London, just after the nightly occurrence.
        DateTime.utc(2026, 10, 21, 1, 3),
      ];
      for (final anchor in anchors) {
        final fresh = backendAt(anchor);
        await fresh.request('scheduler.list');
        final runs = maps(
          (await fresh.request('scheduler.runs'))['runs'],
        ).map(ScheduleRun.fromJson);
        expect(runs.where((r) => r.active), isEmpty, reason: '$anchor');
        // The first poll must not have started anything either.
        final listed = await fresh.request('scheduler.list');
        expect(
          maps(listed['schedules'])
              .where((r) => r['enabled'] == true)
              .every((r) => r['nextOccurrence'] as int > ms(anchor)),
          isTrue,
          reason: '$anchor',
        );
      }
    });

    test('concurrent first requests seed once', () async {
      final fresh = backendAt(t);
      final results = await Future.wait([
        fresh.request('scheduler.list'),
        fresh.request('scheduler.list'),
        fresh.request('scheduler.runs'),
      ]);
      expect(maps(results[0]['schedules']).length, 3);
      expect(maps(results[1]['oneOffSchedules']).length, 2);
    });
  });

  group('list', () {
    test('upcoming is a day of ascending occurrences, none for paused or one-offs', () async {
      final l = await list();
      expect(l['projects'], [
        {
          'projectId': kDemoProjectId,
          'label': kDemoDisplayName,
          'isGitRepository': true,
        },
      ]);
      for (final r in maps(l['schedules'])) {
        final upcoming = (r['upcoming'] as List).cast<int>();
        if (r['enabled'] != true) {
          expect(upcoming, isEmpty, reason: '${r['id']}');
          continue;
        }
        expect(upcoming, isNotEmpty);
        expect(upcoming.length, lessThanOrEqualTo(48));
        expect(upcoming.first, greaterThan(ms(t)));
        expect(upcoming.last, lessThan(ms(t.add(const Duration(hours: 24)))));
        expect([...upcoming]..sort(), upcoming);
      }
      final smoke = maps(
        l['schedules'],
      ).firstWhere((r) => r['id'] == kDemoScheduleSmokeId);
      expect((smoke['upcoming'] as List).length, 24);
      for (final r in maps(l['oneOffSchedules'])) {
        expect(r.containsKey('upcoming'), isFalse);
        expect(r.containsKey('cron'), isFalse);
        expect(r['nextOccurrence'], r['runAt']);
      }
      expect(
        maps(l['schedules']).every((r) => !r.containsKey('runAt')),
        isTrue,
      );
    });

    test('two reads with no write between them agree on every row\'s settings', () async {
      final first = await rows();
      final second = await rows();
      expect(second.length, first.length);
      for (var i = 0; i < first.length; i++) {
        expect(
          AgentSchedule.fromJson(second[i]).settings(),
          AgentSchedule.fromJson(first[i]).settings(),
          reason: '${first[i]['id']}',
        );
      }
    });

    test('settings stay put across polls while time passes with no run created', () async {
      final before = AgentSchedule.fromJson(
        await row(kDemoScheduleDepsId),
      ).settings();
      t = t.add(const Duration(seconds: 30));
      expect(
        AgentSchedule.fromJson(await row(kDemoScheduleDepsId)).settings(),
        before,
      );
    });
  });

  group('create', () {
    test('normalises the cron and round-trips the editor settings', () async {
      final sent = newSchedule(
        mode: 'chat',
        workspace: 'worktree',
        cron: '  */5   *  * * *  ',
        extra: {
          'chatMode': 'plan',
          'baseBranch': 'main',
          'catchUp': 'skip',
          'id': 'sneaky',
          'nextOccurrence': 5,
        },
      );
      final created = await create(sent);
      expect(created['id'], startsWith('demo-schedule-'));
      expect(created['id'], isNot('sneaky'));
      expect(created['cron'], '*/5 * * * *');
      expect(created.containsKey('upcoming'), isFalse);
      expect(created['workspaceCreated'], isFalse);
      expect(created['nextOccurrence'], isNot(5));
      final expected = {...sent}
        ..remove('id')
        ..remove('nextOccurrence')
        ..['cron'] = '*/5 * * * *';
      expect(AgentSchedule.fromJson(created).settings(), expected);
      expect(
        AgentSchedule.fromJson(await row(created['id'] as String)).settings(),
        expected,
      );
    });

    test('a wall-time one-off becomes London epoch milliseconds', () async {
      final created = await create(
        newSchedule(runAt: '2026-10-21T13:00', cron: null),
      );
      expect(created['runAt'], ms(DateTime.utc(2026, 10, 21, 12)));
      expect(created.containsKey('cron'), isFalse);
      expect(created['nextOccurrence'], created['runAt']);
      final listed = await list();
      expect(
        maps(listed['oneOffSchedules']).map((r) => r['id']),
        contains(created['id']),
      );
      expect(
        maps(listed['schedules']).map((r) => r['id']),
        isNot(contains(created['id'])),
      );
    });

    test('drops chatMode outside chat mode or under bypass, and empty baseBranch', () async {
      final terminal = await create(
        newSchedule(extra: {'chatMode': 'plan', 'baseBranch': ''}),
      );
      expect(terminal.containsKey('chatMode'), isFalse);
      expect(terminal.containsKey('baseBranch'), isFalse);
      final bypass = await create(
        newSchedule(
          mode: 'chat',
          extra: {'chatMode': 'plan', 'approvalPolicy': 'bypass'},
        ),
      );
      expect(bypass.containsKey('chatMode'), isFalse);
    });

    test('refuses a one-off in the past, and a bad cron, without adding anything', () async {
      final before = (await rows()).length;
      await expectLater(
        create(newSchedule(runAt: '2026-10-21T11:00', cron: null)),
        _refusal(
          'INVALID_RUN_AT',
          'The one-off time has already passed; set a new time.',
        ),
      );
      await expectLater(
        create(newSchedule(cron: '0 9 * *')),
        _refusal('SCHEDULER_INVALID_CRON'),
      );
      await expectLater(
        create(newSchedule(runAt: '2026-03-29T01:30', cron: null)),
        _refusal('INVALID_RUN_AT'),
      );
      expect((await rows()).length, before);
    });

    test('refuses shapes the editor cannot produce', () async {
      await expectLater(
        create(newSchedule(extra: {'projectId': 'elsewhere'})),
        _refusal(
          'SCHEDULER_ERROR',
          'Project is unavailable; open it from the desktop first',
        ),
      );
      await expectLater(
        create(newSchedule(extra: {'agentId': 'nobody'})),
        _refusal('AGENT_NOT_SCHEDULABLE'),
      );
      await expectLater(
        create(newSchedule(extra: {'name': ''})),
        _refusal('SCHEDULER_ERROR'),
      );
    });
  });

  group('preview', () {
    test('returns five occurrences after now', () async {
      final r = await rq('scheduler.preview', {
        'cron': '0 9 * * *',
        'timezone': 'Europe/London',
      });
      final at = (r['occurrences'] as List).cast<int>();
      expect(at.length, 5);
      expect(at.first, ms(DateTime.utc(2026, 10, 22, 8)));
      expect([...at]..sort(), at);
    });

    test('a missing timezone reads in the sample zone', () async {
      final r = await rq('scheduler.preview', {'cron': '0 9 * * *'});
      expect((r['occurrences'] as List).first, ms(DateTime.utc(2026, 10, 22, 8)));
    });

    test('resolves a one-off, refuses a gap time and a past time', () async {
      final ok = await rq('scheduler.preview', {
        'runAt': '2026-10-21T11:09',
        'timezone': 'Europe/London',
      });
      expect(ok['occurrences'], [ms(DateTime.utc(2026, 10, 21, 10, 9))]);
      await expectLater(
        rq('scheduler.preview', {
          'runAt': '2026-03-29T01:30',
          'timezone': 'Europe/London',
        }),
        _refusal('INVALID_RUN_AT'),
      );
      await expectLater(
        rq('scheduler.preview', {
          'runAt': '2026-10-21T11:00',
          'timezone': 'Europe/London',
        }),
        _refusal(
          'INVALID_RUN_AT',
          'The one-off time has already passed; set a new time.',
        ),
      );
      // Under a minute away counts as passed, like on save.
      await expectLater(
        rq('scheduler.preview', {
          'runAt': '2026-10-21T11:07:30',
          'timezone': 'Europe/London',
        }),
        _refusal('INVALID_RUN_AT'),
      );
    });

    test('refuses a bad cron with the bridge code', () async {
      await expectLater(
        rq('scheduler.preview', {'cron': '99 * * * *', 'timezone': 'UTC'}),
        _refusal('SCHEDULER_INVALID_CRON'),
      );
    });
  });

  group('update', () {
    test('pausing and resuming', () async {
      await rq('scheduler.update', {
        'id': kDemoScheduleNightlyId,
        'patch': {'enabled': false},
      });
      var nightly = await row(kDemoScheduleNightlyId);
      expect(nightly['enabled'], isFalse);
      final l = await list();
      expect(
        (maps(l['schedules']).firstWhere((r) => r['id'] == kDemoScheduleNightlyId)['upcoming'] as List),
        isEmpty,
      );
      await rq('scheduler.update', {
        'id': kDemoScheduleNightlyId,
        'patch': {'enabled': true},
      });
      nightly = await row(kDemoScheduleNightlyId);
      expect(nightly['enabled'], isTrue);
      expect(nightly['nextOccurrence'] as int, greaterThan(ms(t)));
      expect(nightly['updatedAt'], ms(t));
    });

    test('switches a timetable to a one-off and back', () async {
      final once = (await rq('scheduler.update', {
        'id': kDemoScheduleSmokeId,
        'patch': {'runAt': '2026-10-21T13:00'},
      }))['schedule'] as Map;
      expect(once['runAt'], ms(DateTime.utc(2026, 10, 21, 12)));
      expect(once.containsKey('cron'), isFalse);
      expect(
        maps((await list())['oneOffSchedules']).map((r) => r['id']),
        contains(kDemoScheduleSmokeId),
      );
      final cron = (await rq('scheduler.update', {
        'id': kDemoScheduleSmokeId,
        'patch': {'cron': '30 * * * *'},
      }))['schedule'] as Map;
      expect(cron['cron'], '30 * * * *');
      expect(cron.containsKey('runAt'), isFalse);
      expect(cron['nextOccurrence'], ms(DateTime.utc(2026, 10, 21, 10, 30)));
    });

    test('a changed runAt clears the fired state', () async {
      final updated = (await rq('scheduler.update', {
        'id': kDemoScheduleTagId,
        'patch': {'runAt': '2026-10-22T09:00'},
      }))['schedule'] as Map;
      expect(updated.containsKey('firedRunId'), isFalse);
      expect(updated.containsKey('firedAt'), isFalse);
      expect(updated['runAt'], ms(DateTime.utc(2026, 10, 22, 8)));
    });

    test('moving a pending one-off moves its next run with it', () async {
      final updated = (await rq('scheduler.update', {
        'id': kDemoScheduleReleaseNotesId,
        'patch': {'runAt': '2026-10-22T09:00'},
      }))['schedule'] as Map;
      expect(updated['runAt'], ms(DateTime.utc(2026, 10, 22, 8)));
      expect(updated['nextOccurrence'], updated['runAt']);
    });

    test('an untouched runAt keeps its stored value and fired state', () async {
      final before = await row(kDemoScheduleTagId);
      final updated = (await rq('scheduler.update', {
        'id': kDemoScheduleTagId,
        'patch': {'prompt': 'Tag it again.'},
      }))['schedule'] as Map;
      expect(updated['runAt'], before['runAt']);
      expect(updated['firedRunId'], kDemoTagReleaseRunId);
    });

    test('a changed one-off time must still be in the future', () async {
      await expectLater(
        rq('scheduler.update', {
          'id': kDemoScheduleReleaseNotesId,
          'patch': {'runAt': '2026-10-21T11:00'},
        }),
        _refusal('INVALID_RUN_AT'),
      );
    });

    test('null clears baseBranch and chatMode', () async {
      final made = await create(
        newSchedule(
          mode: 'chat',
          workspace: 'worktree',
          extra: {'chatMode': 'plan', 'baseBranch': 'main'},
        ),
      );
      expect(made['baseBranch'], 'main');
      final updated = (await rq('scheduler.update', {
        'id': made['id'],
        'patch': {'baseBranch': null, 'chatMode': null},
      }))['schedule'] as Map;
      expect(updated.containsKey('baseBranch'), isFalse);
      expect(updated.containsKey('chatMode'), isFalse);
    });

    test('a locked schedule keeps its project, workspace and base branch', () async {
      final updated = (await rq('scheduler.update', {
        'id': kDemoScheduleNightlyId,
        'patch': {
          'projectId': 'other',
          'workspace': 'shared',
          'baseBranch': 'dev',
          'name': 'Renamed',
        },
      }))['schedule'] as Map;
      expect(updated['name'], 'Renamed');
      expect(updated['projectId'], kDemoProjectId);
      expect(updated['workspace'], 'worktree');
      expect(updated['baseBranch'], 'main');
    });

    test('unmodelled keys are ignored, not refused', () async {
      final updated = (await rq('scheduler.update', {
        'id': kDemoScheduleSmokeId,
        'patch': {'name': 'Smoke', 'id': 'x', 'somethingNew': 1},
      }))['schedule'] as Map;
      expect(updated['name'], 'Smoke');
      expect(updated['id'], kDemoScheduleSmokeId);
    });

    test('resuming a paused schedule schedules the next occurrence and records nothing', () async {
      final before = (await runsOf(kDemoScheduleDepsId)).length;
      final updated = (await rq('scheduler.update', {
        'id': kDemoScheduleDepsId,
        'patch': {'enabled': true},
      }))['schedule'] as Map;
      expect(
        updated['nextOccurrence'],
        ms(DemoCron.parse('0 10 * * 1').after(t, london, count: 1).first),
      );
      expect((await runsOf(kDemoScheduleDepsId)).length, before);
      // Nor does the next poll.
      await list();
      expect((await runsOf(kDemoScheduleDepsId)).length, before);
    });

    test('an unknown id is the one refusal a viewer cannot reach', () async {
      await expectLater(
        rq('scheduler.update', {'id': 'nope', 'patch': {'name': 'x'}}),
        _refusal('SCHEDULE_NOT_FOUND', 'Schedule no longer exists'),
      );
    });
  });

  group('runNow', () {
    test('creates the workspace in the same step as the run', () async {
      final made = await create(
        newSchedule(name: 'My Nightly!', workspace: 'worktree'),
      );
      expect(made['workspaceCreated'], isFalse);
      final run = ((await rq('scheduler.runNow', {'id': made['id']}))['run']
              as Map)
          .cast<String, dynamic>();
      expect(run['status'], 'preparing');
      expect(run.containsKey('sessionId'), isFalse);
      // t has not moved, so the run is still preparing.
      final after = await row(made['id'] as String);
      expect(after['workspaceCreated'], isTrue);
      expect(after['checkoutId'], 'my-nightly');
      expect(run['trigger'], 'manual');
      expect(run['scheduleName'], 'My Nightly!');
    });

    test('a manual run goes preparing, running, completed', () async {
      final started = t;
      final run = ((await rq('scheduler.runNow', {'id': kDemoScheduleDepsId}))['run']
              as Map)
          .cast<String, dynamic>();
      expect(run['status'], 'preparing');
      expect(run.containsKey('sessionId'), isFalse);
      expect(run.containsKey('runtimeGeneration'), isFalse);
      final id = run['id'] as String;

      ScheduleRun find(List<ScheduleRun> all) => all.firstWhere((r) => r.id == id);

      t = started.add(kDemoRunPreparing + const Duration(seconds: 1));
      var now = find(await runsOf(kDemoScheduleDepsId));
      expect(now.status, 'running');
      expect(now.sessionId, kDemoSessionCartId);
      expect(now.runtimeGeneration, 'demo');
      expect(now.checkoutId, 'weekly-dependency-updates');

      // Run now while it runs hands back the same run.
      final again = ((await rq('scheduler.runNow', {'id': kDemoScheduleDepsId}))['run']
              as Map)
          .cast<String, dynamic>();
      expect(again['id'], id);
      expect(again['status'], isNot('skipped'));
      expect(
        (await runsOf(kDemoScheduleDepsId)).where((r) => r.trigger == 'manual').length,
        1,
      );

      t = started.add(kDemoManualRunDuration + const Duration(seconds: 1));
      now = find(await runsOf(kDemoScheduleDepsId));
      expect(now.status, 'completed');
      expect(now.finishedAt!.difference(now.startedAt!), kDemoManualRunDuration);
    });

    test('an unknown or deleted schedule answers with nothing', () async {
      expect(await rq('scheduler.runNow', {'id': 'nope'}), isEmpty);
      await rq('scheduler.delete', {'id': kDemoScheduleSmokeId});
      expect(await rq('scheduler.runNow', {'id': kDemoScheduleSmokeId}), isEmpty);
    });
  });

  group('stop', () {
    test('interrupts an active run, then answers with nothing', () async {
      final started = t;
      final run = ((await rq('scheduler.runNow', {'id': kDemoScheduleDepsId}))['run']
              as Map)['id'] as String;
      t = started.add(const Duration(seconds: 5));
      expect(await rq('scheduler.stop', {'id': run}), isEmpty);
      final stopped = (await runsOf()).firstWhere((r) => r.id == run);
      expect(stopped.status, 'interrupted');
      expect(stopped.reason, 'Stopped by user');
      expect(stopped.finishedAt, t);
      expect(stopped.sessionId, kDemoSessionCartId);
      expect(await rq('scheduler.stop', {'id': run}), isEmpty);
      expect((await runsOf()).firstWhere((r) => r.id == run).status, 'interrupted');
    });

    test('a run stopped while still starting never binds a session', () async {
      final run = ((await rq('scheduler.runNow', {'id': kDemoScheduleDepsId}))['run']
              as Map)['id'] as String;
      await rq('scheduler.stop', {'id': run});
      final stopped = (await runsOf()).firstWhere((r) => r.id == run);
      expect(stopped.status, 'interrupted');
      expect(stopped.sessionId, isNull);
    });

    test('an unknown or finished run answers with nothing', () async {
      expect(await rq('scheduler.stop', {'id': 'nope'}), isEmpty);
      expect(await rq('scheduler.stop', {'id': kDemoTagReleaseRunId}), isEmpty);
      expect(
        (await runsOf()).firstWhere((r) => r.id == kDemoTagReleaseRunId).status,
        'completed',
      );
    });
  });

  group('delete', () {
    test('removes the schedule from the list and keeps its runs', () async {
      final before = (await runsOf(kDemoScheduleSmokeId)).length;
      expect(await rq('scheduler.delete', {'id': kDemoScheduleSmokeId}), isEmpty);
      expect((await rows()).map((r) => r['id']), isNot(contains(kDemoScheduleSmokeId)));
      expect((await runsOf(kDemoScheduleSmokeId)).length, before);
      expect((await runsOf()).any((r) => r.scheduleId == kDemoScheduleSmokeId), true);
      await expectLater(
        rq('scheduler.update', {'id': kDemoScheduleSmokeId, 'patch': {'name': 'x'}}),
        _refusal('SCHEDULE_NOT_FOUND'),
      );
    });

    test('an unknown id answers with nothing', () async {
      expect(await rq('scheduler.delete', {'id': 'nope'}), isEmpty);
    });

    test('runs come newest first', () async {
      final runs = await runsOf();
      for (var i = 1; i < runs.length; i++) {
        expect(
          runs[i - 1].startedAt!.isBefore(runs[i].startedAt!),
          isFalse,
        );
      }
    });
  });

  group('time passing', () {
    test('an hourly schedule runs at the top of the hour', () async {
      final before = await runsOf(kDemoScheduleSmokeId);
      t = DateTime.utc(2026, 10, 21, 11, 0, 2);
      final after = await runsOf(kDemoScheduleSmokeId);
      final added = after.where((r) => !before.any((b) => b.id == r.id)).toList();
      expect(added.length, 1);
      expect(added.single.trigger, 'cron');
      expect(added.single.occurrenceAt, DateTime.utc(2026, 10, 21, 11));
      expect(
        (await row(kDemoScheduleSmokeId))['nextOccurrence'],
        ms(DateTime.utc(2026, 10, 21, 12)),
      );
      // A second poll in the same minute adds nothing.
      expect((await runsOf(kDemoScheduleSmokeId)).length, after.length);
    });

    test('a due one-off fires and reads as finished', () async {
      await list();
      t = DateTime.utc(2026, 10, 21, 13, 5);
      final notes = AgentSchedule.fromJson(
        await row(kDemoScheduleReleaseNotesId),
      );
      expect(notes.firedRunId, isNotNull);
      final run = (await runsOf(kDemoScheduleReleaseNotesId)).single;
      expect(run.id, notes.firedRunId);
      expect(run.trigger, 'cron');
      expect(notes.workspaceCreated, isTrue);
      expect(schedulerOneOffState(notes, t), SchedulerOneOffState.finished);
    });

    test('a long gap keeps only the latest 48 occurrences', () async {
      final made = await create(newSchedule(cron: '*/5 * * * *'));
      final id = made['id'] as String;
      t = t.add(const Duration(hours: 20));
      final runs = await runsOf(id);
      expect(runs.length, 48);
      final newest = runs.map((r) => r.occurrenceAt).reduce((a, b) => a.isAfter(b) ? a : b);
      expect(t.difference(newest), lessThan(const Duration(minutes: 5)));
      expect(runs.every((r) => r.status == 'completed' || r.active), isTrue);
      expect(runs.every((r) => r.status != 'skipped' && r.status != 'missed'), true);
    });

    test('a one-off waits for its schedule\'s active run to end', () async {
      final made = await create(
        newSchedule(runAt: '2026-10-21T11:09', cron: null),
      );
      final id = made['id'] as String;
      t = DateTime.utc(2026, 10, 21, 10, 8, 45);
      await rq('scheduler.runNow', {'id': id});
      // The one-off's time arrives while the manual run (20 s) is still going.
      t = DateTime.utc(2026, 10, 21, 10, 9, 2);
      expect((await row(id)).containsKey('firedRunId'), isFalse);
      t = DateTime.utc(2026, 10, 21, 10, 9, 10);
      final fired = await row(id);
      expect(fired['firedRunId'], isNotNull);
      expect(
        (await runsOf(id)).map((r) => r.trigger).toSet(),
        {'manual', 'cron'},
      );
    });

    test('old inactive runs are pruned to a bounded history', () async {
      final made = await create(newSchedule(cron: '* * * * *'));
      final id = made['id'] as String;
      // Each step is under a day, so each poll adds up to 48 runs.
      for (var i = 0; i < 8; i++) {
        t = t.add(const Duration(hours: 12));
        await runsOf(id);
      }
      expect((await runsOf(id)).length, lessThanOrEqualTo(200 + 1));
    });
  });

  test('an unknown method names itself', () async {
    await expectLater(
      rq('scheduler.nope'),
      _refusal('E_UNKNOWN_METHOD', 'Unknown scheduler method scheduler.nope'),
    );
  });

  test('no verb answers with the demo refusal', () async {
    final seen = <Object?>[];
    Future<void> run(String m, [_Json p = const {}]) async {
      try {
        seen.add(await rq(m, p));
      } on RpcException catch (e) {
        seen.add('${e.code} ${e.message}');
      }
    }

    await run('scheduler.capabilities');
    await run('scheduler.list');
    await run('scheduler.runs');
    await run('scheduler.preview', {'cron': '0 9 * * *', 'timezone': 'UTC'});
    await run('scheduler.create', {'schedule': newSchedule()});
    await run('scheduler.update', {
      'id': kDemoScheduleSmokeId,
      'patch': {'name': 'x', 'workspace': 'worktree', 'mystery': true},
    });
    await run('scheduler.runNow', {'id': kDemoScheduleDepsId});
    await run('scheduler.stop', {'id': 'nope'});
    await run('scheduler.delete', {'id': 'nope'});
    final blob = jsonEncode(seen);
    expect(blob, isNot(contains(kDemoRefusalCode)));
    expect(blob, isNot(contains(kDemoRefusalText)));
  });
}
