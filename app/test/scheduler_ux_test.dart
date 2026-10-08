import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_prompt_field.dart';
import 'package:antgrid/design/widgets/ab_segmented.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/scheduler_drafts.dart';
import 'package:antgrid/providers/scheduler_timezone.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/scheduler_screen.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/widgets/scheduler/schedule_editor.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
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
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: child ?? const SchedulerScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder field(String hint) =>
    find.byWidgetPredicate((w) => w is AbTextField && w.hintText == hint);
AbButton saveButton(WidgetTester tester) =>
    tester.widget<AbButton>(find.widgetWithText(AbButton, 'Save schedule'));
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
  await tester.tap(
    find.byWidgetPredicate(
      (w) =>
          w is AbIconButton && (w.tooltip?.startsWith('Actions for ') ?? false),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

void main() {
  test('cadence, durations, DST and unknown zones format host instants', () {
    expect(
      schedulerCadence('15 18 * * 1-5', 'Asia/Kolkata'),
      'Weekdays at 18:15 · Asia/Kolkata',
    );
    expect(schedulerCadence('*/7 * * * *', 'UTC'), '*/7 * * * * · UTC');
    expect(schedulerDuration(const Duration(seconds: 7199)), '1h 59m');
    expect(schedulerDuration(const Duration(seconds: 125)), '2m 5s');
    expect(schedulerDuration(const Duration(seconds: -5)), '0s');
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
      expect(find.text('Active run: Needs input'), findsOneWidget);
      expect(find.text('Last occurrence: Skipped'), findsOneWidget);
      expect(find.text('Run now'), findsNothing);
      expect(find.text('Open session'), findsOneWidget);
      expect(find.text('Stop run'), findsOneWidget);
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
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      expect(field('Asia/Kolkata'), findsNothing);
      expect(find.textContaining('Use local timezone'), findsNothing);
      expect(
        host.calls.lastWhere((c) => c.method == 'scheduler.preview').params,
        {'cron': '0 9 * * *', 'timezone': 'America/New_York'},
      );
      expect(find.text('Time (HH:mm) · America/New_York'), findsOneWidget);
      await tester.enterText(field('Schedule name'), 'Daily local review');
      await tester.enterText(find.byType(AbPromptField), 'Review open changes');

      container.read(deviceTimezoneProvider.notifier).set('Europe/London');
      await tester.pumpAndSettle();
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SCHEDULES'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Time (HH:mm) · America/New_York'), findsOneWidget);
      await tester.tap(find.text('Save schedule'));
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
      expect(
        find.text('Next: 2 Jan 2026, 14:30 · Asia/Kolkata (IST)'),
        findsOneWidget,
      );
      await editSchedule(tester);
      expect(field('Asia/Kolkata'), findsNothing);
      expect(find.text('Time (HH:mm) · UTC'), findsOneWidget);
      await tester.tap(find.text('Save schedule'));
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
        await tester.tap(find.text('Create schedule'));
        await tester.pumpAndSettle();
        expect(field('Asia/Kolkata'), findsNothing);
        expect(find.textContaining('Use local timezone'), findsNothing);
        expect(find.text('Time (HH:mm) · $hostZone'), findsOneWidget);
        expect(
          find.textContaining('Could not detect your local timezone'),
          findsNothing,
        );
        expect(find.textContaining('Invalid cron or timezone'), findsNothing);
        expect(
          host.calls.lastWhere((c) => c.method == 'scheduler.preview').params,
          {'cron': '0 9 * * *', 'timezone': hostZone},
        );
        expect(
          find.text('Next five occurrences · machine time'),
          findsOneWidget,
        );
        expect(saveButton(tester).onTap, isNotNull);
        await tester.enterText(field('Schedule name'), 'Machine time review');
        await tester.enterText(
          find.byType(AbPromptField),
          'Review open changes',
        );
        await tester.tap(find.text('Save schedule'));
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
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Time (HH:mm) · Europe/London'), findsOneWidget);
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
      expect(find.text('Preparing'), findsOneWidget);
      await tester.tap(find.text('View run').first);
      await tester.pump();
      expect(find.text('Show all runs'), findsOneWidget);
      final card = tester.widget<Container>(
        find.byKey(const ValueKey('scheduler-run-manual')),
      );
      final context = tester.element(
        find.byKey(const ValueKey('scheduler-run-manual')),
      );
      expect(
        (card.decoration as BoxDecoration).border!.top.color,
        context.antgrid.accent,
      );
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
      expect(find.text('The prompt turn ended.'), findsOneWidget);
      expect(find.textContaining('America/New_York'), findsOneWidget);
      expect(find.textContaining('Asia/Kolkata'), findsNWidgets(2));
      expect(find.text('Run now · Duration: 2m 5s'), findsOneWidget);
      await tester.tap(find.text('Stop run'));
      await tester.pumpAndSettle();
      expect(find.text('Interrupted'), findsOneWidget);
      expect(find.text('Stop run'), findsNothing);
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
      await tester.ensureVisible(find.text('Custom'));
      await tester.tap(find.text('Custom'));
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
      expect(
        tester.widget<AbChip>(find.widgetWithText(AbChip, 'Custom')).selected,
        isTrue,
      );
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      await editSchedule(tester);
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'Daily review',
      );
      await tester.tap(find.text('Local machine'));
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
      expect(find.text('Discard editable changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(
        container.read(schedulerDraftsProvider).values.single.values['name'],
        'Changed',
      );
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      expect(container.read(schedulerDraftsProvider), isEmpty);
      await editSchedule(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard editable changes?'), findsNothing);
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
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Schedule name'), 'Creation draft');
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        '',
      );
      await tester.tap(find.text('Local machine'));
      await tester.pumpAndSettle();
      host.agentAvailable = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create schedule'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbTextField>(field('Schedule name')).controller!.text,
        'Creation draft',
      );
      expect(saveButton(tester).onTap, isNull);
      expect(
        find.text(
          'Select an installed agent and a mode with observable completion.',
        ),
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
      await tester.tap(find.text('Custom'));
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
      await tester.enterText(field('main'), 'feature');
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
      await tester.tap(find.text('Keep my editable changes'));
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
      await tester.tap(find.text('Reload saved settings'));
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
        await tester.enterText(field('main'), '');
        await tester.pumpAndSettle();
        if (!supported) {
          expect(saveButton(tester).onTap, isNull);
          expect(
            find.textContaining('Upgrade the target bridge to clear'),
            findsOneWidget,
          );
          await tester.enterText(field('main'), 'main');
          await tester.pumpAndSettle();
          expect(saveButton(tester).onTap, isNotNull);
        } else {
          await tester.tap(find.text('Save schedule'));
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
        expect(
          find.text('Catches up latest missed run'),
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
          find.text('Run the latest missed run'),
          supported ? findsOneWidget : findsNothing,
        );
        if (supported) {
          expect(find.textContaining('within 15 minutes'), findsOneWidget);
          await tester.tap(find.text('Skip missed runs'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Save schedule'));
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
    expect(schedulerCatchUpSummary('skip'), 'Skips missed runs');
    expect(schedulerCatchUpSummary('latest'), 'Catches up latest missed run');
  });

  test('drafts default catchUp to latest, including drafts saved without it', () {
    final draft = SchedulerDraft(
      values: {'cron': '0 9 * * *'},
      initialSaved: {'cron': '0 9 * * *'},
      frequency: 'Daily',
      time: '09:00',
    );
    expect(draft.values['catchUp'], 'latest');
    expect(draft.dirty, isFalse);
  });

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
          {...runRecord('late', 'completed', at: 1798000000000), 'trigger': 'catch-up'},
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
      String local(int ms) => schedulerLocalTime(
        DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        'Asia/Kolkata',
      );
      expect(
        find.text('${local(1800000000000)} – ${local(1800000000000 + 86400000)}'),
        findsOneWidget,
      );
      expect(find.text('Missed 1 run'), findsOneWidget);
      expect(find.textContaining('${local(1797000000000)} – '), findsNothing);
      expect(find.text('Missed 1000+ runs'), findsOneWidget);
      expect(find.text('Missed runs'), findsOneWidget);
      expect(find.text('Missed while paused'), findsOneWidget);
      expect(find.textContaining('Catch-up · Duration'), findsOneWidget);
      expect(find.textContaining('Missed 1000+ runs · Duration'), findsNothing);
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
      await tester.ensureVisible(find.text('Custom'));
      await tester.tap(find.text('Custom'));
      await tester.pump();
      final cron = tester.widget<AbTextField>(field('0 9 * * 1-5'));
      expect(cron.controller!.text, '15 18 * * 1-5');
      expect(cron.focusNode!.hasFocus, isTrue);
      await tester.tap(find.text('Daily'));
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
      await tester.tap(find.text('Laptop'));
      await tester.pump();
      host.history!.complete({
        'runs': [runRecord('stale', 'needs-input')],
      });
      host.history = null;
      await tester.pumpAndSettle();
      expect(
        tester.widget<AbChip>(find.widgetWithText(AbChip, 'Laptop')).selected,
        isTrue,
      );
      expect(find.text('Active run: Needs input'), findsNothing);
      expect(find.text('Local machine'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  schedulerTestWidgets(
    'mobile controls reach 48px and the footer remains visible above the keyboard with large text',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      sizeView(tester, const Size(400, 800));
      final host = Host();
      final container = containerFor(host);
      await pumpScreen(tester, container, scale: 1.5);
      expect(
        tester.getSize(find.widgetWithText(AbButton, 'Run now')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithText(AbChip, 'Laptop')).height,
        greaterThanOrEqualTo(48),
      );
      final tabs = find.descendant(
        of: find.byType(AbSegmented<bool>),
        matching: find.byType(GestureDetector),
      );
      for (final tab in tabs.evaluate()) {
        expect(
          tester.getSize(find.byElementPredicate((e) => e == tab)).height,
          greaterThanOrEqualTo(48),
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
        tester.getBottomLeft(find.widgetWithText(AbButton, 'Save schedule')).dy,
        lessThanOrEqualTo(500),
      );
      expect(
        tester.getSize(find.widgetWithText(AbButton, 'Cancel')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
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
              ...runRecord('previous', 'completed', at: 1799913600000),
              'finishedAt': 1799913735000,
            },
          ];
        host.preview = (_) async => {
          'occurrences': [
            for (final day in [15, 18, 19, 20, 21])
              DateTime.utc(2027, 1, day, 3, 30).millisecondsSinceEpoch,
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
          await tester.ensureVisible(find.text('Time (HH:mm) · Asia/Kolkata'));
          await tester.pumpAndSettle();
          await capture('editor-timing');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
