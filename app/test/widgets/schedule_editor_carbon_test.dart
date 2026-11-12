import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_agent_mark.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/widgets/scheduler/schedule_editor.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scheduler_ux_test.dart'
    show
        EmptyAgentCatalog,
        Host,
        field,
        option,
        optionSelected,
        pickEvery,
        promptField,
        saveButton,
        seg,
        settings;

/// Runs [body] under a platform override, which is what picks Carbon's
/// density (touch on phones and tablets, compact on desktops).
void platformTest(
  String description,
  TargetPlatform platform,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<SchedulerSnapshot> pumpEditor(
  WidgetTester tester,
  Host host, {
  Size size = const Size(1200, 900),
  double scale = 1,
  bool writable = true,
  bool existing = true,
  bool deleted = false,
  VoidCallback? onClose,
  VoidCallback? onSaved,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final snapshot = await host.snapshot();
  final schedule = existing ? snapshot.schedules.first : null;
  final shown = deleted
      ? SchedulerSnapshot(
          capabilities: snapshot.capabilities,
          projects: snapshot.projects,
          schedules: const [],
          runs: snapshot.runs,
        )
      : snapshot;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentCatalogProvider.overrideWith(EmptyAgentCatalog.new),
        schedulerMachinesProvider.overrideWithValue(const {
          'local': 'Local machine',
        }),
      ],
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
        home: Scaffold(
          body: ScheduleEditor(
            snapshot: shown,
            request: host.request,
            writable: writable,
            schedule: schedule,
            onClose: onClose ?? () {},
            onSaved: onSaved ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return snapshot;
}

/// The names of every `Ab*` widget under the editor's Carbon scope, skipping
/// the agent mark: its logo is content imagery and legitimately builds Ab
/// widgets of its own.
List<String> abWidgetsInScope(WidgetTester tester) {
  final found = <String>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is AbAgentMark) return;
    final name = widget.runtimeType.toString();
    if (name.startsWith('Ab')) found.add(name);
    element.visitChildren(visit);
  }

  tester
      .element(
        find.descendant(
          of: find.byType(ScheduleEditor),
          matching: find.byType(AbCarbonScope),
        ),
      )
      .visitChildren(visit);
  return found;
}

Size boxOf(WidgetTester tester, Finder input) => tester.getSize(
  find
      .descendant(of: input, matching: find.byType(CarbonActionFieldBox))
      .first,
);

Finder get nameInput =>
    find.byWidgetPredicate((w) => w is CarbonTextInput && w.label == 'Name');

void main() {
  platformTest('the pane is one Carbon scope with no Ab control inside it', TargetPlatform.windows, (
    tester,
  ) async {
    await pumpEditor(tester, Host()..oneOffSupported = true);
    final editor = tester.element(find.byType(ScheduleEditor));
    final roots = <Widget>[];
    editor.visitChildren((e) => roots.add(e.widget));
    expect(roots.single, isA<AbCarbonScope>());
    expect(find.byType(AbCarbonScope), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
    expect(find.byType(CarbonForm), findsOneWidget);
    expect(
      find.byType(CarbonFormSection),
      findsAtLeastNWidgets(5),
      reason: 'Task, When, Agent, Workspace and Summary',
    );
  });

  platformTest(
    'the discard confirmation is a Carbon danger modal',
    TargetPlatform.windows,
    (tester) async {
      await pumpEditor(tester, Host());
      await tester.enterText(nameInput, 'Changed');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(CarbonModal), findsOneWidget);
      expect(find.text('Discard changes?'), findsOneWidget);
      final discard = tester.widget<CarbonButton>(
        find.widgetWithText(CarbonButton, 'Discard draft'),
      );
      expect(discard.kind, CarbonButtonKind.danger);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(CarbonModal), findsNothing);
      expect(
        tester.widget<CarbonTextInput>(nameInput).controller!.text,
        'Changed',
        reason: 'dismissing the modal keeps editing',
      );
    },
  );

  group('density', () {
    platformTest('desktop controls use the compact scale', TargetPlatform.windows, (
      tester,
    ) async {
      await pumpEditor(tester, Host());
      expect(boxOf(tester, nameInput).height, 32);
      expect(
        tester.getSize(find.widgetWithText(CarbonButton, 'Save changes')).height,
        32,
      );
      expect(
        tester.getSize(find.widgetWithText(CarbonButton, 'Cancel')).height,
        32,
      );
      expect(tester.getSize(find.byType(CarbonToggle)).height, 32);
      expect(
        tester.getSize(find.byType(CarbonContentSwitcher<String>).first).height,
        40,
      );
    });

    platformTest('phone controls use the touch scale', TargetPlatform.android, (
      tester,
    ) async {
      await pumpEditor(tester, Host(), size: const Size(400, 900));
      expect(boxOf(tester, nameInput).height, 48);
      expect(
        tester.getSize(find.widgetWithText(CarbonButton, 'Save changes')).height,
        48,
      );
      expect(
        tester.getSize(find.widgetWithText(CarbonButton, 'Cancel')).height,
        48,
      );
      expect(tester.getSize(find.byType(CarbonToggle)).height, 48);
      expect(
        tester.getSize(find.byType(CarbonContentSwitcher<String>).first).height,
        48,
      );
      expect(
        tester.getSize(find.byType(CarbonContainedListRow).first).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('200% text at 360 wide', () {
    // Each variant mounts different rows, so each is laid out on its own.
    final variants = <String, Future<void> Function(WidgetTester, Host)>{
      'a saved schedule': (tester, host) async {},
      'a dirty draft with the cron input': (tester, host) async {
        // Picked first: a focused text field scrolls itself back into view and
        // would carry the select off-screen before it opens.
        await pickEvery(tester, 'Custom');
        await tester.enterText(nameInput, 'A much longer schedule name that wraps');
      },
      'a failed preview': (tester, host) async {},
      'a one-off': (tester, host) async {
        await tester.ensureVisible(seg('Once'));
        await tester.tap(seg('Once'));
        await tester.pumpAndSettle();
      },
    };
    for (final MapEntry(key: name, value: prepare) in variants.entries) {
      platformTest(name, TargetPlatform.android, (tester) async {
        final host = Host()
          ..oneOffSupported = true
          ..chatModesListed = true;
        if (name == 'a failed preview') {
          host.previewError = StateError('Preview unavailable');
        }
        await pumpEditor(
          tester,
          host,
          size: const Size(360, 800),
          scale: 2,
        );
        await prepare(tester, host);
        expect(tester.takeException(), isNull);
        final scroller = find
            .descendant(
              of: find.byType(ScheduleEditor),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.drag(scroller, const Offset(0, -4000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(ScheduleEditor)).width,
          360,
          reason: 'nothing pushes the pane wider than the screen',
        );
      });
    }
  });

  platformTest('Tab reaches Save in reading order', TargetPlatform.windows, (
    tester,
  ) async {
    await pumpEditor(tester, Host());
    String? describe() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final button = context.findAncestorWidgetOfExactType<CarbonButton>();
      if (button != null) return 'button:${button.label}';
      final input = context.findAncestorWidgetOfExactType<CarbonTextInput>();
      if (input != null) return 'input:${input.label}';
      if (context.findAncestorWidgetOfExactType<CarbonToggle>() != null) {
        return 'toggle';
      }
      return null;
    }

    final visited = <String>[];
    for (var i = 0; i < 80; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final here = describe();
      if (here != null && !visited.contains(here)) visited.add(here);
      if (here == 'button:Save changes') break;
    }
    expect(visited.last, 'button:Save changes');
    int at(String key) => visited.indexOf(key);
    expect(at('button:Schedules'), 0, reason: 'the back control leads');
    expect(at('toggle'), greaterThan(at('button:Schedules')));
    expect(at('input:Name'), greaterThan(at('toggle')));
    expect(at('input:Prompt'), greaterThan(at('input:Name')));
    expect(
      at('button:Cancel'),
      visited.length - 2,
      reason: 'Cancel sits directly before Save',
    );
  });

  group('validation', () {
    platformTest(
      'an invalid time is an error notification announced to assistive tech',
      TargetPlatform.windows,
      (tester) async {
        final announcements = <String>[];
        tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          (message) async {
            if (message is Map && message['type'] == 'announce') {
              announcements.add(
                (message['data'] as Map)['message'] as String? ?? '',
              );
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger
              .setMockDecodedMessageHandler<dynamic>(
                SystemChannels.accessibility,
                null,
              ),
        );
        final semantics = tester.ensureSemantics();
        await pumpEditor(tester, Host());
        expect(find.byType(CarbonNotification), findsNothing);
        await tester.enterText(field('09:00'), '24:00');
        await tester.pumpAndSettle();
        final notice = tester.widget<CarbonNotification>(
          find.byType(CarbonNotification),
        );
        expect(notice.kind, CarbonNotificationKind.error);
        expect(notice.title, 'Enter a valid time from 00:00 to 23:59.');
        expect(
          announcements.any((m) => m.contains('Enter a valid time')),
          isTrue,
          reason: 'the error is announced, not just painted',
        );
        expect(saveButton(tester).onPressed, isNull);
        semantics.dispose();
      },
    );

    platformTest(
      'saving without a name shows the required-fields error as a notification',
      TargetPlatform.windows,
      (tester) async {
        final host = Host();
        await pumpEditor(tester, host);
        await tester.enterText(nameInput, '  ');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        final notice = tester.widget<CarbonNotification>(
          find.byType(CarbonNotification),
        );
        expect(notice.kind, CarbonNotificationKind.error);
        expect(notice.title, 'Name and prompt are required.');
        expect(
          host.calls.where((c) => c.method == 'scheduler.update'),
          isEmpty,
        );
      },
    );

    platformTest(
      'two notices carrying the same sentence do not collide',
      TargetPlatform.windows,
      (tester) async {
        final host = Host();
        await pumpEditor(tester, host);
        host.agentAvailable = false;
        await pumpEditor(tester, host);
        expect(tester.takeException(), isNull);
        expect(
          find.text('Pick an agent installed on Local machine.'),
          findsOneWidget,
        );
      },
    );
  });

  group('choices', () {
    platformTest(
      'choosing another agent sets its mode and clears the chat mode',
      TargetPlatform.windows,
      (tester) async {
        final host = Host()
          ..chatModesListed = true
          ..extraAgents = [
            {
              'agentId': 'codex',
              'modes': ['chat'],
            },
          ];
        await pumpEditor(tester, host);
        await tester.tap(find.byType(CarbonSelect<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('codex').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        final patch =
            host.calls.lastWhere((c) => c.method == 'scheduler.update').params['patch']
                as Map;
        expect(patch['agentId'], 'codex');
        expect(patch['mode'], 'chat');
        expect(patch.containsKey('chatMode'), isFalse);
      },
    );

    platformTest(
      'single-choice lists mark exactly one row selected and move on tap',
      TargetPlatform.windows,
      (tester) async {
        await pumpEditor(tester, Host());
        final once = option(schedulerCatchUpOnceLabel);
        final skip = option(schedulerCatchUpSkipLabel);
        bool selected(Finder f) =>
            tester.widget<CarbonContainedListRow>(f).selected ?? false;
        expect(selected(once), isTrue);
        expect(selected(skip), isFalse);
        await tester.ensureVisible(skip);
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(selected(once), isFalse);
        expect(selected(skip), isTrue);
      },
    );
  });

  group('read-only states', () {
    platformTest(
      'a deleted schedule keeps its prompt selectable but not editable',
      TargetPlatform.windows,
      (tester) async {
        await pumpEditor(tester, Host(), writable: false, deleted: true);
        final prompt = tester.widget<CarbonTextInput>(promptField);
        expect(prompt.enabled, isTrue);
        expect(prompt.readOnly, isTrue);
        expect(tester.widget<CarbonTextInput>(nameInput).enabled, isFalse);
        expect(saveButton(tester).onPressed, isNull);
        expect(find.textContaining('This schedule was deleted'), findsOneWidget);
      },
    );

    platformTest(
      'an offline machine makes the whole form inert',
      TargetPlatform.windows,
      (tester) async {
        await pumpEditor(tester, Host(), writable: false);
        final prompt = tester.widget<CarbonTextInput>(promptField);
        expect(prompt.enabled, isFalse);
        expect(tester.widget<CarbonTextInput>(nameInput).enabled, isFalse);
        expect(saveButton(tester).onPressed, isNull);
        expect(find.textContaining('is offline'), findsOneWidget);
      },
    );
  });

  group('keyboard and assistive technology', () {
    platformTest(
      'arrow keys on a switcher move focus and leave the draft alone',
      TargetPlatform.windows,
      (tester) async {
        final host = Host()
          ..schedules = [
            {...settings, 'cron': '*/5 * * * *'},
          ];
        await pumpEditor(tester, host);
        final cron = field('0 9 * * 1-5');
        expect(cron, findsOneWidget);
        Focus.of(tester.element(seg('Custom'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(cron, findsOneWidget);
        expect(
          tester.widget<CarbonTextInput>(cron).controller!.text,
          '*/5 * * * *',
        );
        // Right from Weekday must not select Custom and pull focus away.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        final input = tester.widget<CarbonTextInput>(cron);
        expect(input.focusNode?.hasFocus ?? false, isFalse);
      },
    );

    platformTest(
      'a phone offers every frequency, including Custom, inside the pane',
      TargetPlatform.android,
      (tester) async {
        await pumpEditor(tester, Host(), size: const Size(360, 800));
        final every = find.byWidgetPredicate(
          (w) => w is CarbonSelect<String> && w.label == 'Every',
        );
        expect(every, findsOneWidget);
        await tester.ensureVisible(every);
        await tester.pumpAndSettle();
        expect(tester.getRect(every).right, lessThanOrEqualTo(360));
        await pickEvery(tester, 'Custom');
        expect(field('0 9 * * 1-5'), findsOneWidget);
      },
    );

    platformTest(
      'read-only choice rows still announce which one is selected',
      TargetPlatform.windows,
      (tester) async {
        final handle = tester.ensureSemantics();
        await pumpEditor(tester, Host(), writable: false);
        final rows = [
          for (final title in [
            schedulerCatchUpOnceLabel,
            schedulerCatchUpSkipLabel,
          ])
            if (option(title).evaluate().isNotEmpty) title,
        ];
        expect(rows, isNotEmpty);
        var selectedRows = 0;
        for (final title in rows) {
          final data = tester.getSemantics(option(title)).getSemanticsData();
          expect(
            data.flagsCollection.isSelected != Tristate.none,
            isTrue,
            reason: title,
          );
          expect(
            data.flagsCollection.isSelected == Tristate.isTrue,
            optionSelected(tester, title),
            reason: title,
          );
          if (optionSelected(tester, title)) selectedRows++;
        }
        expect(selectedRows, 1);
        handle.dispose();
      },
    );

    platformTest(
      'Save keeps focus through a failed save',
      TargetPlatform.windows,
      (tester) async {
        final host = _FailingSaveHost();
        await pumpEditor(tester, host);
        await tester.enterText(nameInput, 'Renamed');
        await tester.pumpAndSettle();
        bool onSave() =>
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<CarbonButton>()
                ?.label ==
            'Save changes';
        for (var i = 0; i < 80 && !onSave(); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(onSave(), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.text('Saving…'), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<CarbonButton>(),
          isNotNull,
          reason: 'focus stays on the busy button',
        );
        host.release.complete();
        await tester.pumpAndSettle();
        expect(find.text('Save changes'), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<CarbonButton>(),
          isNotNull,
          reason: 'focus is still on Save after the failure',
        );
      },
    );
  });

  test('the editor reuses the saved settings fixture', () {
    expect(settings['id'], 'review');
  });
}

class _FailingSaveHost extends Host {
  final release = Completer<void>();

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'scheduler.update') {
      await release.future;
      throw StateError('save refused');
    }
    return super.request(method, params);
  }
}
