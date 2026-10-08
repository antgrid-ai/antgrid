import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'scheduler models accept target-host epochs and preserve workspace settings',
    () {
      final schedule = AgentSchedule.fromJson({
        'id': 's',
        'name': 'Review',
        'projectId': 'repo',
        'agentId': 'claude',
        'mode': 'terminal',
        'prompt': 'Review',
        'approvalPolicy': 'default',
        'workspace': 'worktree',
        'baseBranch': 'main',
        'cron': '0 9 * * 1-5',
        'timezone': 'Asia/Kolkata',
        'enabled': true,
        'checkoutId': 'owned',
        'workspaceCreated': true,
        'nextOccurrence': 1800000000000,
      });
      expect(schedule.checkoutId, 'owned');
      expect(schedule.workspaceCreated, isTrue);
      expect(schedule.nextOccurrence!.isUtc, isTrue);
      expect(schedule.nextOccurrence!.millisecondsSinceEpoch, 1800000000000);
      expect(schedule.settings()['workspace'], 'worktree');
      expect(schedule.settings()['baseBranch'], 'main');
    },
  );

  test(
    'only launched prompt turns with active lifecycle status retain overlap slots',
    () {
      for (final status in [
        'preparing',
        'running',
        'needs-input',
        'completed',
        'failed',
        'interrupted',
        'skipped',
      ]) {
        final run = ScheduleRun.fromJson({
          'id': 'r',
          'scheduleId': 's',
          'projectId': 'p',
          'status': status,
          'trigger': 'cron',
          'occurrenceAt': 1000,
          'startedAt': 1500,
          'finishedAt': 2500,
          'sessionId': 'session',
          'reason': 'Recorded reason',
        });
        expect(
          run.active,
          ['preparing', 'running', 'needs-input'].contains(status),
        );
        expect(run.duration, const Duration(seconds: 1));
        expect(run.sessionId, 'session');
        expect(run.reason, 'Recorded reason');
        expect(run.timezone, isNull);
        expect(
          ScheduleRun.fromJson({
            ...{
              'id': 'old',
              'scheduleId': 's',
              'projectId': 'p',
              'status': 'completed',
              'trigger': 'cron',
              'occurrenceAt': 1000,
            },
            'timezone': 'America/New_York',
          }).timezone,
          'America/New_York',
        );
      }
    },
  );

  test(
    'capability discovery keeps supported agent-mode pairs and storage failure',
    () {
      final capability = SchedulerCapabilities.fromJson({
        'supported': true,
        'timezone': 'Europe/London',
        'agents': [
          {
            'agentId': 'claude',
            'modes': ['terminal', 'chat'],
          },
        ],
        'error': 'Scheduler database unavailable',
      });
      expect(capability.agents.single.modes, ['terminal', 'chat']);
      expect(capability.error, 'Scheduler database unavailable');
      expect(capability.supportsBaseBranchClear, isFalse);
      expect(
        SchedulerCapabilities.fromJson({
          'supportsBaseBranchClear': true,
        }).supportsBaseBranchClear,
        isTrue,
      );
      expect(
        SchedulerCapabilities.fromJson({'supported': false}).supported,
        isFalse,
      );
      expect(
        SchedulerProject.fromJson({
          'projectId': 'p',
          'label': 'Project',
          'isGitRepository': true,
        }).name,
        'Project',
      );
    },
  );

  test('catch-up fields default for old bridges and gate settings()', () {
    final base = {
      'id': 's',
      'name': 'n',
      'projectId': 'p',
      'agentId': 'claude',
      'mode': 'terminal',
      'prompt': 'x',
      'approvalPolicy': 'bypass',
      'workspace': 'shared',
      'cron': '0 9 * * *',
      'timezone': 'UTC',
      'enabled': true,
    };
    final old = AgentSchedule.fromJson(base);
    expect(old.catchUp, 'latest');
    expect(old.settings()['catchUp'], 'latest');
    expect(old.settings(includeCatchUp: false).containsKey('catchUp'), isFalse);
    expect(AgentSchedule.fromJson({...base, 'catchUp': 'skip'}).catchUp, 'skip');
    expect(SchedulerCapabilities.fromJson({}).supportsCatchUp, isFalse);
    expect(
      SchedulerCapabilities.fromJson({'supportsCatchUp': true}).supportsCatchUp,
      isTrue,
    );
    final run = {
      'id': 'r',
      'scheduleId': 's',
      'projectId': 'p',
      'status': 'skipped',
      'trigger': 'missed',
      'occurrenceAt': 1000,
    };
    expect(ScheduleRun.fromJson(run).missedCount, isNull);
    expect(ScheduleRun.fromJson({...run, 'missedCount': 1000}).missedCount, 1000);
  });

  group('one-off schedules', () {
    const base = {
      'id': 's',
      'name': 'Once',
      'projectId': 'repo',
      'agentId': 'claude',
      'mode': 'terminal',
      'prompt': 'Ship',
      'approvalPolicy': 'default',
      'workspace': 'shared',
      'timezone': 'Europe/London',
      'enabled': true,
    };

    test('a cron-less record parses and settings emit only runAt', () {
      final schedule = AgentSchedule.fromJson({
        ...base,
        'runAt': 1800000000000,
        'nextOccurrence': 1800000000000,
      });
      expect(schedule.cron, isNull);
      expect(schedule.isOneOff, isTrue);
      expect(schedule.runAt!.millisecondsSinceEpoch, 1800000000000);
      final settings = schedule.settings();
      expect(settings['runAt'], 1800000000000);
      expect(settings.containsKey('cron'), isFalse);
    });

    test('a recurring record emits cron and never runAt', () {
      final schedule = AgentSchedule.fromJson({...base, 'cron': '0 9 * * *'});
      expect(schedule.isOneOff, isFalse);
      final settings = schedule.settings();
      expect(settings['cron'], '0 9 * * *');
      expect(settings.containsKey('runAt'), isFalse);
    });

    test('author, edited-by and fired fields parse', () {
      final schedule = AgentSchedule.fromJson({
        ...base,
        'runAt': 1800000000000,
        'authorSessionId': 'sess',
        'authorSessionName': 'Fix flake',
        'editedBySessionName': 'Other',
        'editedAt': 1800000001000,
        'firedRunId': 'run-1',
        'firedAt': 1800000002000,
      });
      expect(schedule.authorSessionId, 'sess');
      expect(schedule.authorSessionName, 'Fix flake');
      expect(schedule.editedBySessionName, 'Other');
      expect(schedule.editedAt!.millisecondsSinceEpoch, 1800000001000);
      expect(schedule.firedRunId, 'run-1');
      expect(schedule.firedAt!.millisecondsSinceEpoch, 1800000002000);
    });

    test('supportsOneOff defaults to false for an older bridge', () {
      expect(
        SchedulerCapabilities.fromJson({'supported': true}).supportsOneOff,
        isFalse,
      );
      expect(
        SchedulerCapabilities.fromJson({
          'supported': true,
          'supportsOneOff': true,
        }).supportsOneOff,
        isTrue,
      );
    });
  });
}
