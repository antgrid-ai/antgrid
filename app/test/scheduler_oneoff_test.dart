import 'dart:ui' show Size;

import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_prompt_field.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/scheduler.dart';
import 'package:antgrid/providers/scheduler_drafts.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'scheduler_ux_test.dart';

const futureMs = 4102444800000; // 2100-01-01T00:00Z
const pastMs = 1000000000000; // 2001-09-09T01:46:40Z

Map<String, dynamic> oneOff({
  int runAt = futureMs,
  bool enabled = true,
  Map<String, dynamic> extra = const {},
}) {
  final base = {...settings}..remove('cron');
  return {
    ...base,
    'id': 'once',
    'name': 'Ship it',
    'runAt': runAt,
    'enabled': enabled,
    'nextOccurrence': runAt,
    ...extra,
  };
}

/// The preview is debounced by a timer that pumpAndSettle alone never reaches.
Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Finder chip(String label) => find.widgetWithText(AbChip, label);

String timeText(WidgetTester tester) =>
    tester.widget<AbTextField>(field('yyyy-MM-dd HH:mm')).controller!.text;

Map<String, dynamic> lastPatch(Host host) =>
    host.calls.lastWhere((c) => c.method == 'scheduler.update').params['patch']
        as Map<String, dynamic>;

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (w) =>
          w is AbIconButton && (w.tooltip?.startsWith('Actions for ') ?? false),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> run(String status, {String trigger = 'cron'}) => {
  ...runRecord('run-f', status),
  'scheduleId': 'once',
  'trigger': trigger,
};

void main() {
  test('list merges oneOffSchedules; an old shape stays cron-only', () async {
    final host = Host()..oneOffs = [oneOff()];
    final merged = await host.snapshot();
    expect(merged.schedules.map((s) => s.id), ['review', 'once']);
    expect(merged.schedules.last.isOneOff, isTrue);

    host.oneOffs = [];
    expect(
      (await host.request('scheduler.list')).containsKey('oneOffSchedules'),
      isFalse,
    );
    final old = await host.snapshot();
    expect(old.schedules.map((s) => s.id), ['review']);
  });

  test('a draft retained from before the fire renews on reopen', () async {
    final host = Host()..oneOffs = [oneOff(runAt: pastMs)];
    final pending = (await host.snapshot()).schedules.last;
    final now = DateTime.utc(2026, 10, 8, 12);
    final retained = SchedulerDraft.start(
      await host.snapshot(),
      pending,
      now: now,
    );
    expect(retained.time, '2001-09-09 07:16');
    host.oneOffs = [
      oneOff(runAt: pastMs, extra: {'firedRunId': 'r', 'firedAt': pastMs}),
    ];
    final fired = (await host.snapshot()).schedules.last;
    final renewed = retained.renewOneOff(fired, now: now);
    expect(renewed.time, '2026-10-08 18:30');
    expect(renewed.values['runAt'], '2026-10-08T18:30');
    expect(renewed.values['enabled'], isTrue);
    expect(renewed.initialSaved, retained.initialSaved);

    final chosen = retained.edit(
      {...retained.values, 'runAt': '2100-02-02T10:00'},
      'Once',
      '2100-02-02 10:00',
    );
    expect(identical(chosen.renewOneOff(fired, now: now), chosen), isTrue);
  });

  schedulerTestWidgets(
    'Set a new time reopens a retained draft on a future time and saves it',
    (tester) async {
      sizeView(tester);
      final host = Host()
        ..oneOffSupported = true
        ..schedules = []
        ..oneOffs = [oneOff(runAt: pastMs)];
      final container = containerFor(host);
      await pumpScreen(tester, container);
      await editSchedule(tester);
      expect(timeText(tester), '2001-09-09 07:16');
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      host.oneOffs = [
        oneOff(runAt: pastMs, extra: {'firedRunId': 'r', 'firedAt': pastMs}),
      ];
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SCHEDULES'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AbButton, 'Set a new time'));
      await settle(tester);
      final now = schedulerWallTime(DateTime.now(), 'Asia/Kolkata');
      final suggested = timeText(tester);
      expect(suggested.compareTo(now), greaterThan(0));
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      final patch = lastPatch(host);
      expect(patch['runAt'], schedulerWallIso(suggested));
      expect(patch['enabled'], isTrue);
      expect(patch.containsKey('cron'), isFalse);
    },
  );

  schedulerTestWidgets('a retained one-off draft keeps and sends its edited time', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()
      ..oneOffSupported = true
      ..schedules = []
      ..oneOffs = [oneOff()];
    await pumpScreen(tester, containerFor(host));
    await editSchedule(tester);
    await tester.enterText(field('yyyy-MM-dd HH:mm'), '2100-02-02 10:00');
    await settle(tester);
    await tester.tap(find.text('RUNS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SCHEDULES'));
    await tester.pumpAndSettle();
    expect(find.text('Editable draft retained'), findsOneWidget);
    await editSchedule(tester);
    expect(timeText(tester), '2100-02-02 10:00');
    await tester.tap(find.text('Save schedule'));
    await tester.pumpAndSettle();
    final patch = lastPatch(host);
    expect(patch['runAt'], '2100-02-02T10:00');
    expect(patch.containsKey('cron'), isFalse);
  });

  schedulerTestWidgets('an edit converting a one-off to Repeats sends only cron', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()
      ..oneOffSupported = true
      ..schedules = []
      ..oneOffs = [oneOff()];
    await pumpScreen(tester, containerFor(host));
    await editSchedule(tester);
    await tester.tap(chip('Repeats'));
    await settle(tester);
    await tester.tap(find.text('Save schedule'));
    await tester.pumpAndSettle();
    final patch = lastPatch(host);
    expect(patch['cron'], '0 9 * * *');
    expect(patch.containsKey('runAt'), isFalse);
  });

  schedulerTestWidgets('an edit converting a recurring schedule to Once sends only runAt', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()..oneOffSupported = true;
    await pumpScreen(tester, containerFor(host));
    await editSchedule(tester);
    await tester.tap(chip('Once'));
    await tester.pumpAndSettle();
    await tester.enterText(field('yyyy-MM-dd HH:mm'), '2100-03-04 09:15');
    await settle(tester);
    await tester.tap(find.text('Save schedule'));
    await tester.pumpAndSettle();
    final patch = lastPatch(host);
    expect(patch['runAt'], '2100-03-04T09:15');
    expect(patch.containsKey('cron'), isFalse);
  });

  schedulerTestWidgets(
    'a deleted one-off draft with unparsed time text reopens',
    (tester) async {
      sizeView(tester);
      final host = Host()
        ..oneOffSupported = true
        ..schedules = []
        ..oneOffs = [oneOff()];
      await pumpScreen(tester, containerFor(host));
      await editSchedule(tester);
      await tester.enterText(field('yyyy-MM-dd HH:mm'), 'next tuesday');
      await settle(tester);
      await tester.tap(find.text('RUNS'));
      await tester.pumpAndSettle();
      host.oneOffs = [];
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SCHEDULES'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open retained draft'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(timeText(tester), 'next tuesday');
      expect(find.textContaining('This schedule was deleted'), findsOneWidget);
    },
  );

  for (final (label, record) in [
    (
      'finished',
      oneOff(
        runAt: pastMs,
        extra: {'firedRunId': 'r', 'firedAt': pastMs},
      ),
    ),
    ('paused with its time passed', oneOff(runAt: pastMs, enabled: false)),
  ]) {
    schedulerTestWidgets(
      'a $label one-off menu offers Set a new time and no Resume',
      (tester) async {
        sizeView(tester);
        final host = Host()
          ..oneOffSupported = true
          ..schedules = []
          ..oneOffs = [record];
        await pumpScreen(tester, containerFor(host));
        await openMenu(tester);
        expect(find.text('Set a new time'), findsNWidgets(2));
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Resume'), findsNothing);
        expect(find.text('Pause'), findsNothing);
        await tester.tap(find.text('Set a new time').last);
        await settle(tester);
        expect(chip('Once'), findsOneWidget);
        final now = schedulerWallTime(DateTime.now(), 'Asia/Kolkata');
        expect(timeText(tester).compareTo(now), greaterThan(0));
      },
    );
  }

  schedulerTestWidgets('pending and paused one-off menus keep Edit and Pause or Resume', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()
      ..oneOffSupported = true
      ..schedules = []
      ..oneOffs = [oneOff()];
    await pumpScreen(tester, containerFor(host));
    await openMenu(tester);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Set a new time'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    host.oneOffs = [oneOff(enabled: false)];
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.text('Resume'), findsOneWidget);
  });

  schedulerTestWidgets('the one-off catch-up help follows the choice', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()..oneOffSupported = true;
    await pumpScreen(tester, containerFor(host));
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();
    await tester.tap(chip('Once'));
    await tester.pumpAndSettle();
    expect(find.textContaining('however late'), findsOneWidget);
    await tester.tap(chip('Skip it if missed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('however late'), findsNothing);
    expect(find.textContaining('skipped if the desktop app'), findsOneWidget);
  });

  test('a draft of a one-off starts clean and detects edits', () async {
    final host = Host()..oneOffs = [oneOff()];
    final snapshot = await host.snapshot();
    final schedule = snapshot.schedules.last;
    final draft = SchedulerDraft.start(snapshot, schedule);
    expect(draft.frequency, 'Once');
    expect(draft.time, '2100-01-01 05:30');
    expect(draft.dirty, isFalse);
    expect(draft.changedSince(schedule), isFalse);
    expect(draft.edit(draft.values, 'Once', '2100-01-02 05:30').dirty, isTrue);
  });

  test('a finished one-off opens on a suggested future time', () async {
    final host = Host()
      ..oneOffs = [
        oneOff(runAt: pastMs, extra: {'firedRunId': 'r', 'firedAt': pastMs}),
      ];
    final snapshot = await host.snapshot();
    final draft = SchedulerDraft.start(
      snapshot,
      snapshot.schedules.last,
      now: DateTime.utc(2026, 10, 8, 12),
    );
    expect(draft.time, '2026-10-08 18:30');
    expect(draft.values['runAt'], '2026-10-08T18:30');
    expect(draft.dirty, isTrue);
  });

  test('finished outcome wording follows the fired run', () {
    final s = AgentSchedule.fromJson(
      oneOff(extra: {'firedRunId': 'run-f', 'firedAt': 1800000000000}),
    );
    String outcome(List<Map<String, dynamic>> runs) =>
        schedulerOneOffOutcome(s, runs.map(ScheduleRun.fromJson).toList());
    expect(outcome([]), startsWith('Finished'));
    expect(outcome([run('completed')]), startsWith('Ran'));
    expect(outcome([run('failed')]), startsWith('Failed'));
    expect(outcome([run('interrupted')]), startsWith('Interrupted'));
    expect(outcome([run('needs-input')]), startsWith('Waiting for input'));
    expect(outcome([run('running')]), startsWith('Running'));
    expect(outcome([run('skipped', trigger: 'missed')]), startsWith('Missed'));
  });

  schedulerTestWidgets('Once is hidden without supportsOneOff', (tester) async {
    sizeView(tester);
    await pumpScreen(tester, containerFor(Host()));
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();
    expect(chip('Once'), findsNothing);
    expect(chip('Repeats'), findsNothing);
  });

  schedulerTestWidgets('a Once save sends runAt and no cron', (tester) async {
    sizeView(tester);
    final host = Host()..oneOffSupported = true;
    await pumpScreen(tester, containerFor(host));
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();
    await tester.tap(chip('Once'));
    await tester.pumpAndSettle();
    await tester.enterText(field('yyyy-MM-dd HH:mm'), '2100-03-04 09:15');
    await settle(tester);
    expect(
      host.calls.lastWhere((c) => c.method == 'scheduler.preview').params,
      {'runAt': '2100-03-04T09:15', 'timezone': 'Asia/Kolkata'},
    );
    await tester.enterText(field('Schedule name'), 'Once');
    await tester.enterText(find.byType(AbPromptField), 'Do it');
    await settle(tester);
    await tester.tap(find.text('Save schedule'));
    await tester.pumpAndSettle();
    final saved =
        host.calls
                .lastWhere((c) => c.method == 'scheduler.create')
                .params['schedule']
            as Map;
    expect(saved['runAt'], '2100-03-04T09:15');
    expect(saved.containsKey('cron'), isFalse);
  });

  schedulerTestWidgets('a Repeats save sends cron and no runAt', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()..oneOffSupported = true;
    await pumpScreen(tester, containerFor(host));
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();
    await tester.tap(chip('Once'));
    await tester.pumpAndSettle();
    await tester.tap(chip('Repeats'));
    await settle(tester);
    await tester.enterText(field('Schedule name'), 'Daily');
    await tester.enterText(find.byType(AbPromptField), 'Do it');
    await settle(tester);
    await tester.tap(find.text('Save schedule'));
    await tester.pumpAndSettle();
    final saved =
        host.calls
                .lastWhere((c) => c.method == 'scheduler.create')
                .params['schedule']
            as Map;
    expect(saved['cron'], '0 9 * * *');
    expect(saved.containsKey('runAt'), isFalse);
  });

  schedulerTestWidgets('editing a one-off leaves an unchanged runAt out', (
    tester,
  ) async {
    sizeView(tester);
    final host = Host()
      ..oneOffSupported = true
      ..schedules = []
      ..oneOffs = [oneOff()];
    await pumpScreen(tester, containerFor(host));
    await editSchedule(tester);
    expect(field('yyyy-MM-dd HH:mm'), findsOneWidget);
    await tester.enterText(field('Schedule name'), 'Renamed');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save schedule'));
    await tester.pumpAndSettle();
    final patch =
        host.calls
                .lastWhere((c) => c.method == 'scheduler.update')
                .params['patch']
            as Map;
    expect(patch['name'], 'Renamed');
    expect(patch.containsKey('runAt'), isFalse);
    expect(patch.containsKey('cron'), isFalse);
  });

  schedulerTestWidgets('the four card states and provenance render', (
    tester,
  ) async {
    sizeView(tester, const Size(1200, 1800));
    final host = Host()
      ..schedules = []
      ..oneOffs = [
        oneOff(extra: {'authorSessionName': 'Fix flake'}),
        oneOff(extra: {'id': 'p', 'name': 'Paused', 'enabled': false}),
        oneOff(
          runAt: pastMs,
          extra: {'id': 'pp', 'name': 'Passed', 'enabled': false},
        ),
        oneOff(
          runAt: pastMs,
          extra: {
            'id': 'f',
            'name': 'Fired',
            'firedRunId': 'run-f',
            'firedAt': 1800000000000,
            'editedBySessionName': 'Other',
          },
        ),
      ]
      ..runs = [
        {...runRecord('run-f', 'completed'), 'scheduleId': 'f'},
      ];
    await pumpScreen(tester, containerFor(host));
    expect(find.text('Once · Fri 1 Jan, 05:30'), findsOneWidget);
    expect(find.text('Paused · once at Fri 1 Jan, 05:30'), findsOneWidget);
    expect(find.text('Paused · time passed'), findsOneWidget);
    expect(find.textContaining('Ran · '), findsOneWidget);
    expect(find.text('Created by Fix flake'), findsOneWidget);
    expect(find.text('Edited by Other'), findsOneWidget);
    expect(find.text('Set a new time'), findsNWidgets(2));
  });
}
