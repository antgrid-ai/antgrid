import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_prompt_field.dart';
import 'package:antgrid/design/widgets/ab_segmented.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/design/widgets/ab_tooltip.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/scheduler_drafts.dart';
import 'package:antgrid/providers/scheduler_timezone.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/scheduler_screen.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/widgets/scheduler/schedule_editor.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
import 'package:antgrid/widgets/scheduler/scheduler_lanes.dart';
import 'package:antgrid/widgets/scheduler/scheduler_run_squares.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft;

const settings = <String, dynamic>{
  'id': 'review',
  'name': 'Daily review',
  'projectId': 'repo',
  'agentId': 'claude',
  'mode': 'terminal',
  'prompt': 'Review open changes and summarize the next steps.',
  'workspace': 'worktree',
  'baseBranch': 'main',
  'approvalPolicy': 'default',
  'cron': '0 9 * * 1-5',
  'timezone': 'Asia/Kolkata',
  'enabled': true,
  'nextOccurrence': 1800000000000,
};
Map<String, dynamic> runRecord(
  String id,
  String status, {
  int at = 1800000000000,
  String? reason,
  String? session,
}) => {
  'id': id,
  'scheduleId': 'review',
  'scheduleName': 'Daily review',
  'projectId': 'repo',
  'status': status,
  'trigger': 'manual',
  'occurrenceAt': at,
  'startedAt': at,
  'reason': ?reason,
  'sessionId': ?session,
};
final connectedProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(true),
);
final deviceTimezoneProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController('Asia/Kolkata'),
    );
final userProvider =
    NotifierProvider<ValueController<CurrentUser?>, CurrentUser?>(
      () => ValueController(
        CurrentUser(userId: 'account', email: 'test@example.com'),
      ),
    );

class Host {
  List<Map<String, dynamic>> schedules = [settings];
  List<Map<String, dynamic>> runs = [];
  bool clearSupported = true;
  bool catchUpSupported = true;
  bool oneOffSupported = false;
  bool chatModesListed = false;
  List<Map<String, dynamic>> extraAgents = [];
  List<Map<String, dynamic>> oneOffs = [];
  bool agentAvailable = true;
  String timezone = 'Asia/Kolkata';
  Object? previewError;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? preview;
  Completer<Map<String, dynamic>>? history;
  Map<String, dynamic> runNow = runRecord('manual', 'preparing');
  final calls = <({String method, Map<String, dynamic> params})>[];
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: params));
    switch (method) {
      case 'scheduler.capabilities':
        return {
          'supported': true,
          'timezone': timezone,
          'supportsBaseBranchClear': clearSupported,
          'supportsCatchUp': catchUpSupported,
          'supportsOneOff': oneOffSupported,
          // The bridge's own names (PERMISSION_MODES in antgrid-agents),
          // including a listed mode called "Default".
          if (chatModesListed)
            'chatModes': {
              'claude': [
                {
                  'id': 'default',
                  'name': 'Default',
                  'description': 'Ask before each tool use',
                },
                {
                  'id': 'auto',
                  'name': 'Auto',
                  'description':
                      'Model classifier approves or denies tool prompts',
                },
                {
                  'id': 'acceptEdits',
                  'name': 'Accept edits',
                  'description': 'Auto-approve file edits',
                },
                {
                  'id': 'plan',
                  'name': 'Plan',
                  'description': 'Read-only planning mode',
                },
              ],
            },
          'agents': [
            if (agentAvailable)
              {
                'agentId': 'claude',
                'modes': ['terminal', 'chat'],
              },
            ...extraAgents,
          ],
        };
      case 'scheduler.list':
        return {
          'schedules': schedules,
          // An older bridge sends no such key at all.
          if (oneOffs.isNotEmpty) 'oneOffSchedules': oneOffs,
          'projects': [
            {'projectId': 'repo', 'label': 'Antgrid', 'isGitRepository': true},
          ],
        };
      case 'scheduler.runs':
        return history?.future ?? Future.value({'runs': runs});
      case 'scheduler.preview':
        if (previewError != null) throw previewError!;
        return preview?.call(params) ??
            {
              'occurrences': List.generate(
                5,
                (i) => 1800000000000 + i * 86400000,
              ),
            };
      case 'scheduler.runNow':
        return {'run': runNow};
      case 'scheduler.update':
        final patch = params['patch'] as Map<String, dynamic>;
        // A patch naming one kind's field clears the other, and a new runAt
        // clears fired, as the bridge does.
        Map<String, dynamic> apply(Map<String, dynamic> s) => {
          for (final e in s.entries)
            if (!(patch.containsKey('cron') && e.key == 'runAt') &&
                !(patch.containsKey('runAt') &&
                    const {'cron', 'firedRunId', 'firedAt'}.contains(e.key)))
              e.key: e.value,
          ...patch,
        };
        schedules = [
          for (final s in schedules)
            if (s['id'] == params['id']) apply(s) else s,
        ];
        oneOffs = [
          for (final s in oneOffs)
            if (s['id'] == params['id']) apply(s) else s,
        ];
        return {};
      case 'scheduler.stop':
        runs = [
          for (final r in runs)
            if (r['id'] == params['id'])
              {...r, 'status': 'interrupted', 'reason': 'Stopped by user'}
            else
              r,
        ];
        return {};
      default:
        return {};
    }
  }

  Future<SchedulerSnapshot> snapshot() => SchedulerSnapshot.load(request);
}

class EmptyAgentCatalog extends AgentCatalogNotifier {
  @override
  Map<String, AgentDescriptor> build() => const {};
}

ProviderContainer containerFor(Host host, {Host? remote}) {
  final container = ProviderContainer(
    overrides: [
      currentUserProvider.overrideWith((ref) async => ref.watch(userProvider)),
      schedulerLocalTimezoneProvider.overrideWith(
        (ref) async => ref.watch(deviceTimezoneProvider),
      ),
      schedulerMachinesProvider.overrideWithValue(const {
        'local': 'Local machine',
        'remote': 'Laptop',
      }),
      schedulerTargetProvider.overrideWith(
        (ref) => switch (ref.watch(schedulerMachineProvider)) {
          'remote' => 'remote',
          _ => null,
        },
      ),
      schedulerConnectedProvider.overrideWith(
        (ref) => ref.watch(connectedProvider),
      ),
      schedulerRequestProvider.overrideWith(
        (ref) => ref.watch(schedulerTargetProvider) == 'remote'
            ? (remote ?? host).request
            : host.request,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void sizeView(WidgetTester tester, [Size size = const Size(1200, 900)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> pumpScreen(
  WidgetTester tester,
  ProviderContainer container, {
  Widget? child,
  Key? captureKey,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAbTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: child ?? const SchedulerScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// AbSegmented upper-cases its labels.
Finder seg(String label) => find.text(label.toUpperCase());
Finder option(String title) => find.byKey(ValueKey('scheduler-option-$title'));
bool optionSelected(WidgetTester tester, String title) =>
    tester.widget<Semantics>(option(title)).properties.checked ?? false;

Future<void> pickMachine(WidgetTester tester, String target) async {
  final current = target == 'Laptop' ? 'Local machine' : 'Laptop';
  await tester.tap(find.widgetWithText(AbButton, current));
  await tester.pumpAndSettle();
  await tester.tap(find.text(target).last);
  await tester.pumpAndSettle();
}

Finder field(String hint) =>
    find.byWidgetPredicate((w) => w is AbTextField && w.hintText == hint);
AbButton saveButton(WidgetTester tester) => tester.widget<AbButton>(
  find.byWidgetPredicate(
    (w) =>
        w is AbButton &&
        (w.label == 'Create schedule' || w.label == 'Save changes'),
  ),
);
void schedulerTestWidgets(String description, WidgetTesterCallback callback) {
  ft.testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await callback(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> editSchedule(WidgetTester tester) async {
  final actions = find.byWidgetPredicate(
    (w) =>
        w is AbIconButton && (w.tooltip?.startsWith('Actions for ') ?? false),
  );
  if (actions.evaluate().isEmpty) {
    // Phone rows open the editor on tap; there is no kebab.
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'scheduler-schedule-',
                ),
          )
          .first,
    );
    await tester.pumpAndSettle();
    return;
  }
  final review = find.byWidgetPredicate(
    (w) => w is AbIconButton && w.tooltip == 'Actions for Daily review',
  );
  await tester.tap(review.evaluate().isNotEmpty ? review : actions.first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

void main() {
  test('unknown zones and triggers format host values', () {
    expect(
      schedulerTime(DateTime.utc(2026, 1, 1)),
      '1 Jan 2026, 00:00 · UTC (UTC)',
    );
    expect(schedulerPresetCron('Daily', '23:59'), '59 23 * * *');
    expect(schedulerPresetCron('Daily', '24:00'), isNull);
    expect(
      schedulerTime(DateTime.parse('2026-03-08T07:00:00Z'), 'America/New_York'),
      contains('03:00'),
    );
    expect(
      schedulerTime(DateTime.parse('2026-11-01T05:00:00Z'), 'America/New_York'),
      contains('(EDT)'),
    );
    expect(
      schedulerTime(DateTime.parse('2026-11-01T06:00:00Z'), 'America/New_York'),
      contains('(EST)'),
    );
    expect(
      schedulerTime(DateTime.parse('2026-11-01T06:00:00Z'), 'Moon/Base'),
      contains('UTC (unknown zone: Moon/Base)'),
    );
  });

  schedulerTestWidgets(
    'newer skips leave Needs input actionable and show terminal occurrence separately',
    (tester) async {
      sizeView(tester);
      final host = Host()
        ..runs = [
          runRecord(
            'skip',
            'skipped',
            at: 1800000001000,
            reason: 'Previous occurrence is still active',
          ),
          runRecord(
            'active',
            'needs-input',
            reason: 'Permission required',
            session: 'session',
          ),
        ];
      await pumpScreen(tester, containerFor(host));
      expect(find.textContaining('Needs input · waiting'), findsOneWidget);
      expect(find.textContaining('Skipped'), findsWidgets);
      expect(find.text('Run now'), findsNothing);
      expect(find.text('Open session'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Open session for Daily review'),
        findsOneWidget,
      );
    },
  );

  schedulerTestWidgets(
    'creation uses device-local time even when the host is UTC and retains its zone after a device change',
    (tester) async {
      sizeView(tester);
      final host = Host()..timezone = 'UTC';
      final container = containerFor(host);
      container.read(deviceTimezoneProvider.notifier).set('America/New_York');
      await pumpScreen(tester, container);
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      expect(field('Asia/Kolkata'), findsNothing);
      expect(find.textContaining('Use local timezone'), findsNothing);
      expect(
        host.calls.lastWhere((c) => c.method == 'scheduler.preview').params,
        {'cron': '0 9 * * *', 'timezone': 'America/New_York'},
      );
      expect(find.text('America/New_York'), findsOneWidget);
      await tester.enterText(field('Schedule name'), 'Daily local review');
      await tester.enterText(find.byType(AbPromptField), 'Review open changes');

      container.read(deviceTimezoneProvider.notifier).set('Europe/London');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Schedules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SCHEDULES'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      expect(find.text('America/New_York'), findsOneWidget);
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      final saved =
          host.calls
                  .lastWhere((c) => c.method == 'scheduler.create')
                  .params['schedule']
              as Map;
      expect(saved['timezone'], 'America/New_York');
      expect(saved['cron'], '0 9 * * *');
    },
  );

  schedulerTestWidgets(
    'existing UTC rules keep their timezone while next occurrences display locally',
    (tester) async {
      sizeView(tester);
      final instant = DateTime.utc(2026, 1, 2, 9);
      final host = Host()
        ..timezone = 'UTC'
        ..schedules = [
          {
            ...settings,
            'cron': '0 9 * * *',
            'timezone': 'UTC',
            'nextOccurrence': instant.millisecondsSinceEpoch,
          },
        ];
      await pumpScreen(tester, containerFor(host));
      expect(find.textContaining('2 Jan 14:30'), findsOneWidget);
      expect(find.textContaining('your time'), findsOneWidget);
      expect(find.text('UTC'), findsOneWidget);
      await editSchedule(tester);
      expect(field('Asia/Kolkata'), findsNothing);
      expect(find.text('UTC'), findsOneWidget);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      final patch =
          host.calls
                  .lastWhere((c) => c.method == 'scheduler.update')
                  .params['patch']
              as Map;
      expect(patch['timezone'], 'UTC');
      expect(patch['cron'], '0 9 * * *');
    },
  );

  for (final hostZone in ['UTC', 'Asia/Kolkata']) {
    schedulerTestWidgets(
      'unavailable local detection automatically uses host timezone $hostZone',
      (tester) async {
        sizeView(tester);
        final host = Host()..timezone = hostZone;
        final container = containerFor(host);
        container.read(deviceTimezoneProvider.notifier).set(null);
        await pumpScreen(tester, container);
        await tester.tap(find.text('New schedule'));
        await tester.pumpAndSettle();
        expect(field('Asia/Kolkata'), findsNothing);
        expect(find.textContaining('Use local timezone'), findsNothing);
        expect(find.text(hostZone), findsOneWidget);
        expect(
          find.textContaining('Could not detect your local timezone'),
          findsNothing,
        );
        expect(find.textContaining('Invalid cron or timezone'), findsNothing);
        expect(
          host.calls.lastWhere((c) => c.method == 'scheduler.preview').params,
          {'cron': '0 9 * * *', 'timezone': hostZone},
        );
        expect(find.text('machine time · $hostZone'), findsOneWidget);
        expect(saveButton(tester).onTap, isNotNull);
        await tester.enterText(field('Schedule name'), 'Machine time review');
        await tester.enterText(
          find.byType(AbPromptField),
          'Review open changes',
        );
        await tester.tap(find.text('Create schedule'));
        await tester.pumpAndSettle();
        final saved =
            host.calls
                    .lastWhere((c) => c.method == 'scheduler.create')
                    .params['schedule']
                as Map;
        expect(saved['timezone'], hostZone);
      },
    );
  }

  schedulerTestWidgets(
    'a retained draft with an empty timezone recovers automatically without losing its prompt',
    (tester) async {
      sizeView(tester);
      final host = Host()..timezone = 'Europe/London';
      final container = containerFor(host);
      container.read(deviceTimezoneProvider.notifier).set(null);
      final draft = SchedulerDraft.start(
        await host.snapshot(),
        null,
        localTimezone: '',
      );
      container.read(schedulerDraftsProvider.notifier).put(
        (machine: 'local', scheduleId: null),
        draft.edit(
          {
            ...draft.values,
            'name': 'Retained draft',
            'prompt': 'Keep this prompt',
          },
          'Daily',
          '09:00',
        ),
      );
      await pumpScreen(tester, container);
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Europe/London'), findsOneWidget);
      expect(
        tester
            .widget<AbPromptField>(find.byType(AbPromptField))
            .controller
            .text,
        'Keep this prompt',
      );
      expect(saveButton(tester).onTap, isNotNull);
      expect(
        host.calls
            .lastWhere((c) => c.method == 'scheduler.preview')
            .params['timezone'],
        'Europe/London',
      );
    },
  );

  schedulerTestWidgets(
    'Run now feedback precedes history refresh and View run highlights the returned occurrence',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      host.history = Completer();
      await tester.tap(find.text('Run now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Starting'), findsNWidgets(2));
      await tester.tap(find.text('View run').first);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('scheduler-runs-schedule-filter')),
          matching: find.text('Daily review'),
        ),
        findsOneWidget,
      );
      final card = tester.widget<Container>(
        find.byKey(const ValueKey('scheduler-run-manual')),
      );
      final context = tester.element(
        find.byKey(const ValueKey('scheduler-run-manual')),
      );
      expect(card.color, context.antgrid.bgSelected);
      host.history!.complete({'runs': []});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scheduler-run-manual')),
        findsOneWidget,
      );
    },
  );

  schedulerTestWidgets(
    'manual skips explain exact reason and history navigation selects their run',
    (tester) async {
      sizeView(tester);
      final host = Host()
        ..runNow = runRecord(
          'skip',
          'skipped',
          reason: 'Machine already has two active scheduled runs',
        );
      await pumpScreen(tester, containerFor(host));
      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      expect(
        find.text('Run skipped: Machine already has two active scheduled runs'),
        findsOneWidget,
      );
      await tester.tap(find.text('View run'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scheduler-run-skip')), findsOneWidget);
    },
  );

  schedulerTestWidgets(
    'stop and explicit completion remain distinct and historical zones survive deletion',
    (tester) async {
      sizeView(tester);
      final host = Host()
        ..schedules = []
        ..runs = [
          {
            ...runRecord('complete', 'completed'),
            'timezone': 'America/New_York',
            'finishedAt': 1800000125000,
          },
          runRecord(
            'running',
            'running',
            at: 1800000001000,
            session: 'session',
          ),
        ];
      await pumpScreen(tester, containerFor(host));
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Times in Asia/Kolkata'), findsOneWidget);
      expect(find.textContaining('America/New_York'), findsNothing);
      expect(
        find.text(
          schedulerClock(
            DateTime.fromMillisecondsSinceEpoch(1800000000000, isUtc: true),
            'Asia/Kolkata',
          ),
        ),
        findsNWidgets(2),
      );
      expect(find.text('2m 05s'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Interrupted'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
    },
  );

  schedulerTestWidgets(
    'drafts survive tabs, machines, disposal and returning through navigation',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await editSchedule(tester);
      await tester.enterText(field('Schedule name'), 'My editable title');
      await tester.ensureVisible(seg('Custom'));
      await tester.tap(seg('Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Schedules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SCHEDULES'));
      await tester.pumpAndSettle();
      await editSchedule(tester);
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'My editable title',
      );
      expect(field('0 9 * * 1-5'), findsOneWidget);
      await pickMachine(tester, 'Laptop');
      await tester.pumpAndSettle();
      await editSchedule(tester);
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'Daily review',
      );
      await pickMachine(tester, 'Local machine');
      await tester.pumpAndSettle();
      await editSchedule(tester);
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'My editable title',
      );
      await pumpScreen(tester, container, child: const SizedBox());
      await pumpScreen(tester, container);
      await editSchedule(tester);
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'My editable title',
      );
    },
  );

  schedulerTestWidgets(
    'Cancel confirms dirty drafts and save clears only its draft',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await editSchedule(tester);
      await tester.enterText(field('Schedule name'), 'Changed');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(
        container.read(schedulerDraftsProvider).values.single.values['name'],
        'Changed',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(container.read(schedulerDraftsProvider), isEmpty);
      await editSchedule(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      await editSchedule(tester);
      await tester.enterText(field('Schedule name'), 'Discard this');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard draft'));
      await tester.pumpAndSettle();
      expect(container.read(schedulerDraftsProvider), isEmpty);
    },
  );

  schedulerTestWidgets(
    'creation drafts retain their machine and revalidate missing capabilities',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Schedule name'), 'Creation draft');
      await pickMachine(tester, 'Laptop');
      await tester.pumpAndSettle();
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        '',
      );
      await pickMachine(tester, 'Local machine');
      await tester.pumpAndSettle();
      host.agentAvailable = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'Creation draft',
      );
      expect(saveButton(tester).onTap, isNull);
      expect(
        find.text('Pick an agent installed on Local machine.'),
        findsOneWidget,
      );
      expect(
        container
            .read(schedulerDraftsProvider)
            .keys
            .where((k) => k.scheduleId == null),
        hasLength(2),
      );
      expect(containerFor(host).read(schedulerDraftsProvider), isEmpty);
    },
  );

  schedulerTestWidgets(
    'field labels, focus and menu targets remain accessible',
    (tester) async {
      sizeView(tester);
      final host = Host();
      await pumpScreen(tester, containerFor(host));
      await editSchedule(tester);
      expect(
        tester.getSemantics(field('Schedule name')).getSemanticsData().label,
        contains('Name'),
      );
      await tester.tap(seg('Custom'));
      await tester.pump();
      expect(
        tester.widget<AbTextField>(field('0 9 * * 1-5')).focusNode!.hasFocus,
        isTrue,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard draft'));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is AbIconButton && w.tooltip == 'Actions for Daily review',
        ),
      );
      await tester.pumpAndSettle();
      final menuRow = find
          .ancestor(
            of: find.text('Edit'),
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(tester.getSize(menuRow).height, greaterThanOrEqualTo(48));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsOneWidget);
    },
  );

  schedulerTestWidgets(
    'saved changes, workspace provisioning and deletion revalidate retained drafts',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await editSchedule(tester);
      await tester.enterText(field('Schedule name'), 'My edit');
      await tester.enterText(field('current branch'), 'feature');
      host.schedules = [
        {
          ...settings,
          'name': 'Changed elsewhere',
          'workspaceCreated': true,
          'checkoutId': 'retained-checkout',
        },
      ];
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(saveButton(tester).onTap, isNull);
      expect(find.text('Workspace settings locked'), findsOneWidget);
      await tester.ensureVisible(find.text('Keep mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep mine'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'My edit',
      );
      expect(saveButton(tester).onTap, isNotNull);
      expect(find.text('main'), findsOneWidget);
      host.schedules = [];
      host.runs = [runRecord('active', 'needs-input', session: 'conversation')];
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.textContaining('This schedule was deleted'), findsOneWidget);
      expect(saveButton(tester).onTap, isNull);
      await tester.tap(find.text('Schedules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SCHEDULES'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open retained draft'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'My edit',
      );
    },
  );

  schedulerTestWidgets(
    'Reload uses current saved settings and clears editable changes',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await editSchedule(tester);
      await tester.enterText(field('Schedule name'), 'Draft');
      host.schedules = [
        {...settings, 'name': 'Saved remotely'},
      ];
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use saved version'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'Saved remotely',
      );
      expect(
        container.read(schedulerDraftsProvider).values.single.dirty,
        isFalse,
      );
    },
  );

  test(
    'account changes and logout clear in-memory drafts while loading does not',
    () async {
      final host = Host();
      final container = containerFor(host);
      final snapshot = await host.snapshot();
      final store = container.read(schedulerDraftsProvider.notifier);
      await container.read(currentUserProvider.future);
      const key = (machine: 'local', scheduleId: 'review');
      store.open(key, snapshot, snapshot.schedules.first);
      container.invalidate(currentUserProvider);
      await container.pump();
      expect(container.read(schedulerDraftsProvider), isNotEmpty);
      await container.read(currentUserProvider.future);
      container
          .read(userProvider.notifier)
          .set(CurrentUser(userId: 'other', email: 'other@example.com'));
      await container.read(currentUserProvider.future);
      await container.pump();
      expect(container.read(schedulerDraftsProvider), isEmpty);
      store.open(key, snapshot, snapshot.schedules.first);
      container.read(userProvider.notifier).set(null);
      await container.read(currentUserProvider.future);
      await container.pump();
      expect(container.read(schedulerDraftsProvider), isEmpty);
    },
  );

  for (final supported in [true, false]) {
    schedulerTestWidgets(
      'clearing an existing branch ${supported ? 'sends null' : 'requires a bridge upgrade'}',
      (tester) async {
        sizeView(tester);
        final host = Host()..clearSupported = supported;
        await pumpScreen(tester, containerFor(host));
        await editSchedule(tester);
        await tester.enterText(field('current branch'), '');
        await tester.pumpAndSettle();
        if (!supported) {
          expect(saveButton(tester).onTap, isNull);
          expect(
            find.textContaining('Update Antgrid on Local machine to clear'),
            findsOneWidget,
          );
          await tester.enterText(field('current branch'), 'main');
          await tester.pumpAndSettle();
          expect(saveButton(tester).onTap, isNotNull);
        } else {
          await tester.tap(find.text('Save changes'));
          await tester.pumpAndSettle();
          expect(
            host.calls
                .lastWhere((c) => c.method == 'scheduler.update')
                .params['patch'],
            containsPair('baseBranch', null),
          );
        }
      },
    );
  }

  for (final supported in [true, false]) {
    schedulerTestWidgets(
      'schedule row ${supported ? 'states' : 'omits'} the catch-up policy when the bridge ${supported ? 'supports' : 'lacks'} it',
      (tester) async {
        sizeView(tester);
        final host = Host()..catchUpSupported = supported;
        await pumpScreen(tester, containerFor(host));
        expect(find.text('Daily review'), findsOneWidget);
        expect(find.text('Skip if missed'), findsNothing);
        host.schedules = [
          {...settings, 'catchUp': 'skip'},
        ];
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(
          find.text('Skip if missed'),
          supported ? findsOneWidget : findsNothing,
        );
      },
    );
  }

  for (final supported in [true, false]) {
    schedulerTestWidgets(
      'catch-up choice is ${supported ? 'sent' : 'hidden and omitted'} when the bridge ${supported ? 'supports' : 'lacks'} it',
      (tester) async {
        sizeView(tester);
        final host = Host()..catchUpSupported = supported;
        await pumpScreen(tester, containerFor(host));
        await editSchedule(tester);
        expect(
          option(schedulerCatchUpOnceLabel),
          supported ? findsOneWidget : findsNothing,
        );
        if (supported) {
          expect(
            find.textContaining(
              'Runs the latest missed time when Antgrid opens',
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(option(schedulerCatchUpSkipLabel));
          await tester.pumpAndSettle();
          await tester.tap(option(schedulerCatchUpSkipLabel));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        final patch =
            host.calls
                    .lastWhere((c) => c.method == 'scheduler.update')
                    .params['patch']
                as Map;
        if (supported) {
          expect(patch['catchUp'], 'skip');
        } else {
          expect(patch.containsKey('catchUp'), isFalse);
        }
      },
    );
  }

  test('trigger labels, missed counts and catch-up summaries', () {
    expect(schedulerTrigger('cron'), 'Scheduled');
    expect(schedulerTrigger('manual'), 'Run now');
    expect(schedulerTrigger('missed'), 'Missed');
    expect(schedulerTrigger('catch-up'), 'Catch-up');
    expect(schedulerTrigger('future'), 'future');
    expect(schedulerMissedLabel(1), 'Missed 1 run');
    expect(schedulerMissedLabel(3), 'Missed 3 runs');
    expect(schedulerMissedLabel(1000), 'Missed 1000+ runs');
    expect(schedulerMissedLabel(null), 'Missed runs');
  });

  test(
    'drafts default catchUp to latest, including drafts saved without it',
    () {
      final draft = SchedulerDraft(
        values: {'cron': '0 9 * * *'},
        initialSaved: {'cron': '0 9 * * *'},
        frequency: 'Daily',
        time: '09:00',
      );
      expect(draft.values['catchUp'], 'latest');
      expect(draft.dirty, isFalse);
    },
  );

  schedulerTestWidgets(
    'missed records show the count, interval and no duration; catch-up runs are labelled',
    (tester) async {
      sizeView(tester);
      final host = Host()
        ..schedules = []
        ..runs = [
          {
            ...runRecord('gap', 'skipped', reason: 'Missed while paused'),
            'trigger': 'missed',
            'missedCount': 1000,
            'missedUntil': 1800000000000 + 86400000,
          },
          {
            ...runRecord('old', 'skipped', at: 1799000000000),
            'trigger': 'missed',
            'missedUntil': 1799000000000,
          },
          {
            ...runRecord('late', 'completed', at: 1798000000000),
            'trigger': 'catch-up',
          },
          {
            ...runRecord('single', 'skipped', at: 1797000000000),
            'trigger': 'missed',
            'missedCount': 1,
            'missedUntil': 1797000000000,
          },
        ];
      await pumpScreen(tester, containerFor(host));
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      for (final id in ['gap', 'old', 'single']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('scheduler-run-$id')),
            matching: find.text('Missed'),
          ),
          findsWidgets,
          reason: id,
        );
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('scheduler-run-late')),
          matching: find.text('Completed'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Missed 1000+ runs while closed'),
        findsOneWidget,
      );
      expect(find.textContaining('Missed 1 run while closed'), findsOneWidget);
      expect(find.text('Catch-up'), findsOneWidget);
      expect(find.text('Details'), findsNWidgets(4));
      // Missed records never ran, so no row carries a duration; the one
      // completed catch-up run has none recorded either.
      expect(find.text('—'), findsNWidgets(4));
      for (final tap in find.text('Details').evaluate().toList()) {
        await tester.ensureVisible(find.byElementPredicate((e) => e == tap));
        await tester.tap(find.byElementPredicate((e) => e == tap));
        await tester.pumpAndSettle();
      }
      expect(find.text('Missed while paused'), findsOneWidget);
      expect(
        find.text('Antgrid was not open when this was due.'),
        findsNWidgets(2),
      );
      expect(
        find.text(
          'Antgrid opened after a missed time, so the latest one was run.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(' to ', findRichText: true), findsOneWidget);
    },
  );

  schedulerTestWidgets(
    'Custom preserves cron and focuses it; preset times reject invalid input',
    (tester) async {
      sizeView(tester);
      final host = Host();
      await pumpScreen(tester, containerFor(host));
      await editSchedule(tester);
      await tester.enterText(field('09:00'), '18:15');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(host.calls.last.params['cron'], '15 18 * * 1-5');
      await tester.ensureVisible(seg('Custom'));
      await tester.tap(seg('Custom'));
      await tester.pump();
      final cron = tester.widget<AbTextField>(field('0 9 * * 1-5'));
      expect(cron.controller!.text, '15 18 * * 1-5');
      expect(cron.focusNode!.hasFocus, isTrue);
      await tester.tap(seg('Day'));
      await tester.pump();
      await tester.enterText(field('09:00'), '24:00');
      await tester.pumpAndSettle();
      expect(saveButton(tester).onTap, isNull);
      expect(find.textContaining('Enter a valid time'), findsOneWidget);
      await tester.enterText(field('09:00'), '07:30');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(host.calls.last.params['cron'], '30 7 * * *');
      expect(saveButton(tester).onTap, isNotNull);
    },
  );

  for (final failure in ['operational', 'validation', 'local validation']) {
    final invalid = failure != 'operational';
    schedulerTestWidgets(
      'preview $failure failures classify and recover on retry',
      (tester) async {
        sizeView(tester);
        final host = Host()
          ..previewError = failure == 'local validation'
              ? HostControlException(
                  'SCHEDULER_INVALID_CRON',
                  'Choose an IANA timezone, such as Europe/London',
                )
              : RpcException(
                  invalid ? 'SCHEDULER_INVALID_CRON' : 'SCHEDULER_ERROR',
                  'Preview failed',
                );
        await pumpScreen(tester, containerFor(host));
        await editSchedule(tester);
        expect(
          find.textContaining(
            invalid
                ? 'Invalid cron or timezone'
                : 'Could not validate on this machine',
          ),
          findsOneWidget,
        );
        expect(saveButton(tester).onTap, isNull);
        expect(find.textContaining('HostControlException'), findsNothing);
        expect(find.textContaining('SCHEDULER_INVALID_CRON'), findsNothing);
        if (failure == 'local validation') {
          expect(
            find.textContaining('Choose an IANA timezone'),
            findsOneWidget,
          );
        }
        host.previewError = null;
        await tester.ensureVisible(find.text('Retry validation'));
        await tester.tap(find.text('Retry validation'));
        await tester.pumpAndSettle();
        expect(saveButton(tester).onTap, isNotNull);
      },
    );
  }

  schedulerTestWidgets(
    'reconnection retries the current pair and stale previews cannot enable Save',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await editSchedule(tester);
      final old = Completer<Map<String, dynamic>>();
      host.preview = (params) => params['cron'] == '0 7 * * 1-5'
          ? old.future
          : Future.value({
              'occurrences': [1800000000000],
            });
      await tester.enterText(field('09:00'), '07:00');
      await tester.pump(const Duration(milliseconds: 400));
      expect(saveButton(tester).onTap, isNull);
      await tester.enterText(field('09:00'), '08:00');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      old.completeError(RpcException('SCHEDULER_INVALID_CRON', 'Stale'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Invalid cron'), findsNothing);
      expect(saveButton(tester).onTap, isNotNull);
      container.read(connectedProvider.notifier).set(false);
      await tester.pump();
      expect(saveButton(tester).onTap, isNull);
      container.read(connectedProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(host.calls.last.params['timezone'], 'Asia/Kolkata');
      expect(host.calls.last.params['cron'], '0 8 * * 1-5');
      expect(saveButton(tester).onTap, isNotNull);
    },
  );

  schedulerTestWidgets(
    'stale machine response cannot change the selected machine or action feedback',
    (tester) async {
      sizeView(tester);
      final host = Host();
      final container = containerFor(host, remote: Host());
      await pumpScreen(tester, container);
      host.history = Completer();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await pickMachine(tester, 'Laptop');
      await tester.pump();
      host.history!.complete({
        'runs': [runRecord('stale', 'needs-input')],
      });
      host.history = null;
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AbButton, 'Laptop'), findsOneWidget);
      expect(find.textContaining('Needs input'), findsNothing);
      expect(find.text('Local machine'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  schedulerTestWidgets(
    'mobile controls keep touch-sized targets and the footer remains visible above the keyboard with large text',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      sizeView(tester, const Size(400, 800));
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container, scale: 1.5);
      expect(
        tester.getSize(find.widgetWithText(AbButton, 'Local machine')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(
              find.byWidgetPredicate(
                (w) => w is AbIconButton && w.tooltip == 'New schedule',
              ),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      final tabs = find.descendant(
        of: find.byType(AbSegmented<bool>),
        matching: find.byType(GestureDetector),
      );
      // A segment is its own visible box, so it stops at a row height; it
      // spans half the screen, which keeps it an easy target.
      for (final tab in tabs.evaluate()) {
        expect(
          tester.getSize(find.byElementPredicate((e) => e == tab)).height,
          greaterThanOrEqualTo(AbTokens.rowHeightMd),
        );
      }
      await editSchedule(tester);
      await tester.enterText(
        find.byType(AbPromptField),
        List.filled(100, 'Long prompt').join('\n'),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.widgetWithText(AbButton, 'Save changes')).dy,
        lessThanOrEqualTo(500),
      );
      expect(
        tester.getSize(find.widgetWithText(AbButton, 'Cancel')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    },
  );

  int nowMs() => DateTime.now().millisecondsSinceEpoch;
  const hour = 3600000;

  Map<String, dynamic> laneSchedule(int i, List<int> upcoming) => {
    ...settings,
    'id': 'lane-$i',
    'name': 'Lane $i',
    'upcoming': upcoming,
    'nextOccurrence': upcoming.first,
  };

  schedulerTestWidgets(
    'lane strip draws a lane per schedule with runs in the next 24 hours and caps at six',
    (tester) async {
      sizeView(tester);
      final now = nowMs();
      final host = Host()
        ..schedules = [
          // Soonest first is the sort order, so feed them out of order.
          for (final i in [7, 3, 0, 5, 1, 6, 2, 4])
            laneSchedule(i, [
              now + (i + 1) * hour ~/ 2,
              now + (i + 1) * hour ~/ 2 + 3 * hour,
              now + (i + 1) * hour ~/ 2 + 6 * hour,
            ]),
        ];
      await pumpScreen(tester, containerFor(host));
      final strip = find.byType(SchedulerLaneStrip);
      expect(strip, findsOneWidget);
      expect(
        find.descendant(of: strip, matching: find.text('Next 24 hours')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: strip,
          matching: find.text('Times in Asia/Kolkata'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: strip, matching: find.text('+2 more')),
        findsOneWidget,
      );
      for (var i = 0; i < 6; i++) {
        expect(
          find.descendant(of: strip, matching: find.text('Lane $i')),
          findsOneWidget,
          reason: 'lane $i',
        );
      }
      for (final i in [6, 7]) {
        expect(
          find.descendant(of: strip, matching: find.text('Lane $i')),
          findsNothing,
          reason: 'lane $i is behind +N more',
        );
      }
      final ys = [
        for (var i = 0; i < 6; i++)
          tester
              .getTopLeft(
                find.descendant(of: strip, matching: find.text('Lane $i')),
              )
              .dy,
      ];
      expect(ys, [...ys]..sort());
      expect(ys.toSet(), hasLength(6));
      final dots = find.descendant(of: strip, matching: find.byType(AbTooltip));
      expect(dots, findsNWidgets(18));
      final box = tester.getRect(strip);
      for (final dot in dots.evaluate()) {
        final rect = tester.getRect(find.byElementPredicate((e) => e == dot));
        expect(box.contains(rect.center), isTrue);
        expect(rect.width, greaterThan(0));
      }
    },
  );

  schedulerTestWidgets('lane strip is hidden when nothing is upcoming', (
    tester,
  ) async {
    sizeView(tester);
    await pumpScreen(tester, containerFor(Host()));
    expect(find.text('Daily review'), findsOneWidget);
    expect(find.text('Next 24 hours'), findsNothing);
    expect(find.text('Times in Asia/Kolkata'), findsOneWidget);
  });

  schedulerTestWidgets('paused schedules get no lane', (tester) async {
    sizeView(tester);
    final now = nowMs();
    final host = Host()
      ..schedules = [
        laneSchedule(0, [now + hour]),
        {
          ...laneSchedule(1, [now + 2 * hour]),
          'enabled': false,
        },
      ];
    await pumpScreen(tester, containerFor(host));
    final strip = find.byType(SchedulerLaneStrip);
    expect(
      find.descendant(of: strip, matching: find.text('Lane 0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: strip, matching: find.text('Lane 1')),
      findsNothing,
    );
    expect(find.text('PAUSED AND FINISHED'), findsOneWidget);
  });

  schedulerTestWidgets(
    'recent run squares show the last ten outcomes with the last-run line',
    (tester) async {
      sizeView(tester);
      final now = nowMs();
      final statuses = [
        'failed',
        'completed',
        'completed',
        'interrupted',
        'completed',
        'completed',
        'failed',
        'completed',
        'completed',
        'completed',
        'completed',
        'completed',
      ];
      final host = Host()
        ..schedules = [
          settings,
          {...settings, 'id': 'fresh', 'name': 'Fresh schedule'},
        ]
        ..runs = [
          for (final (i, status) in statuses.indexed)
            {
              ...runRecord(
                'r$i',
                status,
                at: now - (statuses.length - i) * hour,
              ),
              'trigger': 'cron',
              'finishedAt': now - (statuses.length - i) * hour + 100000,
            },
        ];
      await pumpScreen(tester, containerFor(host));
      final squares = find.byType(SchedulerRunSquares);
      expect(squares, findsOneWidget, reason: 'only one schedule has runs');
      final cells = find.descendant(
        of: squares,
        matching: find.byType(AbTooltip),
      );
      expect(cells, findsNWidgets(10));
      for (final cell in cells.evaluate()) {
        final size = tester.getSize(find.byElementPredicate((e) => e == cell));
        expect(size.width, closeTo(9, 0.01));
        expect(size.height, closeTo(9, 0.01));
      }
      expect(find.text('Completed 58m ago · 1m 40s'), findsOneWidget);
      expect(find.text('No runs yet'), findsOneWidget);
    },
  );

  schedulerTestWidgets(
    'run squares drop the oldest runs instead of overflowing a narrow table',
    (tester) async {
      sizeView(tester, const Size(900, 900));
      final now = nowMs();
      final host = Host()
        ..schedules = [settings]
        ..runs = [
          for (var i = 0; i < 10; i++)
            {
              ...runRecord('n$i', 'completed', at: now - (10 - i) * hour),
              'trigger': 'cron',
              'finishedAt': now - (10 - i) * hour + 100000,
            },
        ];
      await pumpScreen(tester, containerFor(host));
      expect(tester.takeException(), isNull);
      final cells = find.descendant(
        of: find.byType(SchedulerRunSquares),
        matching: find.byType(AbTooltip),
      );
      expect(cells.evaluate().length, inInclusiveRange(1, 9));
    },
  );

  schedulerTestWidgets('a waiting run says how long it has been waiting', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()
      ..runs = [
        runRecord(
          'wait',
          'needs-input',
          at: nowMs() - 6 * 60000 - 5000,
          session: 'session',
        ),
      ];
    await pumpScreen(tester, containerFor(host));
    expect(find.text('Needs input · waiting 6m'), findsOneWidget);
    expect(find.text('Open session'), findsOneWidget);
    await tester.tap(find.text('RUNS'));
    await tester.pumpAndSettle();
    expect(find.text('waiting 6m'), findsOneWidget);
  });

  schedulerTestWidgets('Runs chips filter by state and show their counts', (
    tester,
  ) async {
    sizeView(tester);
    final now = nowMs();
    final host = Host()
      ..runs = [
        runRecord('waiting', 'needs-input', at: now - 60000, session: 's'),
        runRecord('bad', 'failed', at: now - 2 * hour),
        {
          ...runRecord('late', 'completed', at: now - 3 * hour),
          'trigger': 'catch-up',
        },
        {
          ...runRecord('gap', 'skipped', at: now - 4 * hour),
          'trigger': 'missed',
        },
        runRecord('fine', 'completed', at: now - 5 * hour),
      ];
    await pumpScreen(tester, containerFor(host));
    await tester.tap(find.text('RUNS'));
    await tester.pumpAndSettle();
    Finder chipFor(String name) =>
        find.byKey(ValueKey('scheduler-runs-filter-$name'));
    Finder row(String id) => find.byKey(ValueKey('scheduler-run-$id'));
    expect(find.text('All 5'), findsOneWidget);
    expect(find.text('Failed 1'), findsOneWidget);
    expect(find.text('Catch-up 2'), findsOneWidget);
    const ids = ['waiting', 'bad', 'late', 'gap', 'fine'];
    for (final (chip, shown) in [
      ('failed', ['bad']),
      ('catchUp', ['late', 'gap']),
      ('all', ids),
    ]) {
      await tester.tap(chipFor(chip));
      await tester.pumpAndSettle();
      for (final id in ids) {
        expect(
          row(id),
          shown.contains(id) ? findsOneWidget : findsNothing,
          reason: '$chip / $id',
        );
      }
    }
  });

  schedulerTestWidgets(
    'Runs group by day in the viewer zone under day headers',
    (tester) async {
      sizeView(tester);
      final now = DateTime.now();
      final today = now.millisecondsSinceEpoch - 60000;
      final twoDays = now.millisecondsSinceEpoch - 2 * 24 * hour;
      final host = Host()
        ..runs = [
          runRecord('a', 'completed', at: today),
          runRecord('b', 'completed', at: twoDays),
          runRecord('c', 'failed', at: twoDays - 1000),
        ];
      await pumpScreen(tester, containerFor(host));
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      DateTime at(int ms) =>
          DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      final todayHeader = schedulerDayHeader(at(today), 'Asia/Kolkata', now);
      final olderHeader = schedulerDayHeader(at(twoDays), 'Asia/Kolkata', now);
      expect(todayHeader, startsWith('Today'));
      expect(find.text(todayHeader.toUpperCase()), findsOneWidget);
      expect(find.text(olderHeader.toUpperCase()), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(todayHeader.toUpperCase())).dy,
        lessThan(tester.getTopLeft(find.text(olderHeader.toUpperCase())).dy),
      );
      double rowTop(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('scheduler-run-$id'))).dy;
      expect(rowTop('a'), lessThan(rowTop('b')));
      expect(rowTop('b'), lessThan(rowTop('c')));
      expect(find.text('Times in Asia/Kolkata'), findsOneWidget);
    },
  );

  schedulerTestWidgets(
    'editor footer says Create schedule for a new schedule and Save changes for an existing one',
    (tester) async {
      sizeView(tester);
      await pumpScreen(tester, containerFor(Host()));
      await tester.tap(find.text('New schedule'));
      await tester.pumpAndSettle();
      final create = find.widgetWithText(AbButton, 'Create schedule');
      expect(create, findsOneWidget);
      expect(find.widgetWithText(AbButton, 'Save changes'), findsNothing);
      expect(tester.getBottomLeft(create).dy, lessThanOrEqualTo(900));
      expect(tester.getTopLeft(create).dy, greaterThan(0));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      if (find.text('Discard draft').evaluate().isNotEmpty) {
        await tester.tap(find.text('Discard draft'));
        await tester.pumpAndSettle();
      }
      await editSchedule(tester);
      final save = find.widgetWithText(AbButton, 'Save changes');
      expect(save, findsOneWidget);
      expect(find.widgetWithText(AbButton, 'Create schedule'), findsNothing);
      expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(900));
    },
  );

  schedulerTestWidgets(
    'phone list counts the runs in the next 24 hours and names the next one',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      sizeView(tester, const Size(400, 850));
      final now = nowMs();
      final host = Host()
        ..schedules = [
          laneSchedule(0, [now + 42 * 60000, now + 3 * hour]),
          laneSchedule(1, [now + 5 * hour]),
        ];
      await pumpScreen(tester, containerFor(host));
      final line = find.text('3 runs in the next 24 hours');
      expect(line, findsOneWidget);
      final box = tester.getRect(line);
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(400));
      expect(find.textContaining('Next: Lane 0'), findsOneWidget);
      expect(find.byType(SchedulerLaneStrip), findsNothing);
    },
  );

  for (final mobile in [false, true]) {
    schedulerTestWidgets(
      'render ${mobile ? 'mobile' : 'desktop'} scheduler review screenshots',
      (tester) async {
        if (mobile) {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
        }
        sizeView(tester, mobile ? const Size(400, 850) : const Size(1400, 950));
        if (const bool.fromEnvironment('SCHEDULER_SCREENSHOTS')) {
          await tester.runAsync(() async {
            await (FontLoader(AbTokens.fontMono)..addFont(
                  rootBundle.load('assets/fonts/JetBrainsMonoNL-Regular.ttf'),
                ))
                .load();
            final bytes = await File(
              'C:/Windows/Fonts/segoeui.ttf',
            ).readAsBytes();
            await (FontLoader(
              AbTokens.fontSans,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          });
        }
        final host = Host()
          ..schedules = [
            {
              ...settings,
              'workspaceCreated': true,
              'checkoutId': 'schedule-review-workspace',
              'nextOccurrence': DateTime.utc(
                2027,
                1,
                15,
                3,
                30,
              ).millisecondsSinceEpoch,
            },
          ]
          ..runs = [
            runRecord(
              'active',
              'needs-input',
              at: DateTime.now().millisecondsSinceEpoch - 135000,
              session: 'conversation',
              reason: 'Approval needed to review repository changes',
            ),
            {
              ...runRecord(
                'previous',
                'completed',
                at: DateTime.now().millisecondsSinceEpoch - 18 * 60000,
              ),
              'finishedAt':
                  DateTime.now().millisecondsSinceEpoch - 18 * 60000 + 100000,
            },
          ];
        // Lanes and run squares are drawn from the live clock, so the fixture
        // is built relative to it.
        final base = DateTime.now().millisecondsSinceEpoch;
        host.schedules = [
          {
            ...host.schedules.single,
            'nextOccurrence': base + 42 * 60000,
            'upcoming': [base + 42 * 60000, base + 42 * 60000 + 24 * hour],
          },
          {
            ...settings,
            'id': 'nightly',
            'name': 'Hourly lint',
            'cron': '0 * * * *',
            'timezone': 'Asia/Kolkata',
            'nextOccurrence': base + 20 * 60000,
            'upcoming': [
              for (var i = 0; i < 18; i++) base + 20 * 60000 + i * hour,
            ],
          },
          {
            ...settings,
            'id': 'audit',
            'name': 'Dependency audit',
            'cron': '30 2 * * *',
            'timezone': 'Europe/London',
            'catchUp': 'skip',
            'nextOccurrence': base + 5 * hour,
            'upcoming': [base + 5 * hour, base + 17 * hour],
          },
          {
            ...settings,
            'id': 'notes',
            'name': 'Release notes',
            'cron': '0 17 * * 5',
            'enabled': false,
          },
        ];
        host.runs = [
          ...host.runs,
          for (var i = 0; i < 12; i++)
            {
              ...runRecord(
                'hist$i',
                i % 5 == 3
                    ? 'failed'
                    : (i % 7 == 4 ? 'interrupted' : 'completed'),
                at: base - (i + 2) * 5 * hour,
              ),
              'trigger': 'cron',
              'finishedAt': base - (i + 2) * 5 * hour + 100000,
            },
          {
            ...runRecord('gap', 'skipped', at: base - 30 * hour),
            'trigger': 'missed',
            'missedCount': 3,
            'reason': 'Antgrid was closed',
          },
        ];
        host.preview = (_) async => {
          'occurrences': [
            for (final day in [1, 2, 3, 4, 5]) base + day * 24 * hour,
          ],
        };
        final key = GlobalKey();
        await pumpScreen(tester, containerFor(host), captureKey: key);
        Future<void> capture(String surface) async {
          if (!const bool.fromEnvironment('SCHEDULER_SCREENSHOTS')) return;
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final dir = Directory('../.tmp/screenshots/scheduler');
            await dir.create(recursive: true);
            await File(
              '${dir.path}/${mobile ? 'mobile' : 'desktop'}-$surface.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('schedules');
        await tester.tap(find.text('RUNS'));
        await tester.pumpAndSettle();
        await capture('runs');
        await tester.tap(find.text('SCHEDULES'));
        await tester.pumpAndSettle();
        await editSchedule(tester);
        await capture('editor');
        if (mobile) {
          await tester.scrollUntilVisible(
            find.text('Asia/Kolkata'),
            300,
            scrollable: find
                .descendant(
                  of: find.byType(ScheduleEditor),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await capture('editor-timing');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
