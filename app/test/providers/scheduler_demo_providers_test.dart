import 'package:antgrid/demo/fixtures/demo_scheduler_fixtures.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/scheduler_drafts.dart';
import 'package:antgrid/providers/scheduler_timezone.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _OneAgentCatalog extends AgentCatalogNotifier {
  @override
  Map<String, AgentDescriptor> build() => const {
    'codex': AgentDescriptor(
      tool: 'codex',
      label: 'Codex CLI',
      chatCapable: true,
      judgeCapable: false,
      handlerTerminal: false,
      handlerChat: false,
    ),
  };
}

const _key = (machine: 'local', scheduleId: null);

SchedulerDraft _draft(String name) => SchedulerDraft(
  values: {'name': name},
  initialSaved: {'name': name},
  frequency: 'Daily',
  time: '09:00',
);

Map<String, dynamic> _schedule(String name) => {
  'name': name,
  'prompt': 'Do the thing',
  'projectId': 'antgrid-demo',
  'agentId': 'claude-code',
  'mode': 'terminal',
  'approvalPolicy': 'default',
  'workspace': 'shared',
  'cron': '0 9 * * *',
  'timezone': 'UTC',
  'enabled': true,
};

Future<List<Object?>> _names(ProviderContainer c) async {
  final listed = await c.read(schedulerRequestProvider)('scheduler.list');
  return [for (final r in listed['schedules'] as List) (r as Map)['name']];
}

void main() {
  late ProviderContainer c;

  setUp(() async {
    c = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((_) async => null),
        schedulerLocalTimezoneProvider.overrideWith((_) async => null),
        agentCatalogProvider.overrideWith(_OneAgentCatalog.new),
      ],
    );
    addTearDown(c.dispose);
    // The first null resolution clears drafts, so let it land before any are
    // written.
    await c.read(currentUserProvider.future);
  });

  void demo(bool on) => c.read(demoModeProvider.notifier).set(on);

  group('demo scheduler backend', () {
    test('lives as long as the flag and is reseeded on re-entry', () async {
      demo(true);
      final first = c.read(demoSchedulerBackendProvider);
      expect(c.read(demoSchedulerBackendProvider), same(first));
      await c.read(schedulerRequestProvider)('scheduler.create', {
        'schedule': _schedule('Made in the sample'),
      });
      expect(await _names(c), contains('Made in the sample'));

      demo(false);
      demo(true);
      expect(c.read(demoSchedulerBackendProvider), isNot(same(first)));
      final names = await _names(c);
      expect(names, isNot(contains('Made in the sample')));
      expect(names, contains(kDemoScheduleNightlyName));
    });
  });

  group('agent labels', () {
    test('are the sample labels in demo', () {
      demo(true);
      expect(c.read(schedulerAgentLabelsProvider), kDemoSchedulerAgentLabels);
    });

    test('come from the catalog outside demo', () {
      expect(c.read(schedulerAgentLabelsProvider), {'codex': 'Codex CLI'});
    });
  });

  group('draft stash', () {
    test('real drafts are set aside on entry', () {
      final drafts = c.read(schedulerDraftsProvider.notifier);
      drafts.put(_key, _draft('real'));
      expect(c.read(schedulerDraftsProvider), contains(_key));
      demo(true);
      expect(c.read(schedulerDraftsProvider), isEmpty);
    });

    test('demo drafts are dropped and real drafts restored on exit', () {
      final drafts = c.read(schedulerDraftsProvider.notifier);
      drafts.put(_key, _draft('real'));
      demo(true);
      drafts.put(_key, _draft('sample'));
      expect(c.read(schedulerDraftsProvider)[_key]!.values['name'], 'sample');
      demo(false);
      expect(c.read(schedulerDraftsProvider)[_key]!.values['name'], 'real');
    });

    test('clear inside the demo leaves both maps empty after exit', () {
      final drafts = c.read(schedulerDraftsProvider.notifier);
      drafts.put(_key, _draft('real'));
      demo(true);
      drafts.put(_key, _draft('sample'));
      drafts.clear();
      demo(false);
      expect(c.read(schedulerDraftsProvider), isEmpty);
    });
  });
}
