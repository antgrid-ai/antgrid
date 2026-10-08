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
}
