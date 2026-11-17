// The Terminals tab: a strip of the session's shells, the active one under a
// toolbar naming where it runs. These pin what the strip offers and what each
// control actually sends to the bridge.
import 'dart:async';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/session_workspace_state.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/widgets/terminal_list_view.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

Future<FakeAgentTransport> _pumpPanel(
  WidgetTester tester, {
  int terminals = 2,
  double width = 800,
  void Function(ProviderContainer container)? beforeStatus,
}) async {
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final session = await newFakeProjectSession(transport, projectId: 'test');
  // Not awaited — see terminal_list_view_empty_state_test.dart.
  addTearDown(() => unawaited(session.close()));

  final prefs = await openAppSettingsPrefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
        clientIdProvider.overrideWith((ref) async => 'this-install'),
        agentTerminalProvider.overrideWith((ref) => null),
        appSettingsServiceProvider.overrideWith(
          () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 500,
              child: const TerminalListView(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (beforeStatus != null) {
    beforeStatus(
      ProviderScope.containerOf(tester.element(find.byType(TerminalListView))),
    );
    await tester.pump();
    await tester.pump();
  }

  transport.emit('agent:status', {
    'projectId': 'test',
    'checkoutPath': '/home/dev/demo-shop',
    'terminals': [
      for (var i = 1; i <= terminals; i++)
        {
          'terminalId': 'terminal-$i',
          'name': 'Terminal $i',
          'running': true,
          'shell': i.isOdd ? '/bin/zsh' : '/bin/bash',
          'cols': 80,
          'rows': 24,
        },
    ],
  });
  await tester.pump();
  await tester.pump();
  transport.clearSent();
  return transport;
}

List<Map<String, dynamic>> _sent(FakeAgentTransport t, String type) =>
    t.sent.where((m) => m['type'] == type).toList();

/// The close glyph on each tab, in tab order. The glyph is not its own
/// semantics node (a tab bar may hold only tabs), so it is found by icon.
Finder _closeGlyphs() => find.byWidgetPredicate(
  (w) => w is CarbonIcon && w.icon == CarbonIcons.close,
);

Finder _scrollButton(CarbonIcons glyph) =>
    find.byWidgetPredicate((w) => w is CarbonIcon && w.icon == glyph);

/// A start the fake bridge never answers arms the service's start deadline;
/// run it out so the test ends with no timer pending.
Future<void> _outlastStartDeadline(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 16));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every terminal gets a pill; the first is open under a toolbar '
      'naming its folder', (tester) async {
    await _pumpPanel(tester);

    expect(find.text('Terminal 1'), findsOneWidget);
    expect(find.text('Terminal 2'), findsOneWidget);
    // The pill names the terminal, not the shell binary behind it.
    expect(find.text('zsh'), findsNothing);
    expect(find.text('/home/dev/demo-shop'), findsOneWidget);
    for (final action in ['Clear', 'Restart', 'Kill']) {
      expect(find.text(action), findsOneWidget);
    }
  });

  testWidgets('New opens the next terminal straight away, with no menu', (
    tester,
  ) async {
    final transport = await _pumpPanel(tester);

    await tester.tap(find.text('New'));
    await tester.pump();

    final start = _sent(transport, 'terminal:start').single;
    expect(start['terminalId'], 'terminal-3');
    // The host's default shell: the app names none.
    expect(start.containsKey('command'), isFalse);
    expect(find.text('Terminal 3'), findsOneWidget);
    await _outlastStartDeadline(tester);
  });

  testWidgets('a pill’s close kills that terminal', (tester) async {
    final transport = await _pumpPanel(tester);

    await tester.tap(_closeGlyphs().last);
    await tester.pump();

    expect(_sent(transport, 'terminal:stop').single['terminalId'], 'terminal-2');
    expect(find.text('Terminal 2'), findsNothing);
  });

  testWidgets('Kill on a terminal shown without a recorded pick moves to its '
      'left neighbour', (tester) async {
    await _pumpPanel(tester, terminals: 3);

    await tester.tap(find.text('Terminal 3'));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-3')), findsOneWidget);

    await tester.tap(find.text('Kill'));
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-2')), findsOneWidget);
  });

  // A reconnect starts a fresh service with no tabs until agent:status; the
  // pick must outlast that gap, not be forgotten in it.
  testWidgets('a picked terminal survives its tab list arriving late', (
    tester,
  ) async {
    const key = (entryId: 'test', sessionId: 's1');
    await _pumpPanel(
      tester,
      terminals: 3,
      beforeStatus: (container) {
        container.read(activeSessionIdProvider.notifier).set('s1');
        container
            .read(sessionWorkspaceStateProvider(key).notifier)
            .update((s) => s.copyWith(selectedTerminalId: 'terminal-2'));
      },
    );

    expect(find.byKey(const ValueKey('terminal-2')), findsOneWidget);
  });

  testWidgets('Restart respawns the open terminal in place', (tester) async {
    final transport = await _pumpPanel(tester);

    await tester.tap(find.text('Restart'));
    await tester.pump();

    expect(
      _sent(transport, 'terminal:start').single['terminalId'],
      'terminal-1',
    );
    await _outlastStartDeadline(tester);
  });

  testWidgets('no running count anywhere in the panel', (tester) async {
    await _pumpPanel(tester);
    expect(find.textContaining('running'), findsNothing);
  });

  testWidgets('a tab is spoken with its run state, and closing it is a '
      'Kill action', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpPanel(tester);

    final one = tester.getSemantics(find.text('Terminal 1')).getSemanticsData();
    expect(one.label, 'Terminal 1, running');
    final two = tester.getSemantics(find.text('Terminal 2')).getSemanticsData();
    final labels = [
      for (final id in two.customSemanticsActionIds ?? const <int>[])
        CustomSemanticsAction.getAction(id)!.label,
    ];
    expect(labels, contains('Kill Terminal 2, running'));
    handle.dispose();
  });

  testWidgets('New stops at ten terminals and says why', (tester) async {
    final transport = await _pumpPanel(tester, terminals: 10);

    await tester.tap(find.text('New'));
    await tester.pump();

    expect(_sent(transport, 'terminal:start'), isEmpty);
    expect(
      find.byWidgetPredicate(
        (w) => w is CarbonTooltip && w.message == 'Max terminals reached',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a tab tap hands the keyboard to the terminal it opened', (
    tester,
  ) async {
    await _pumpPanel(tester, terminals: 3);

    await tester.tap(find.text('Terminal 3'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-3')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'TerminalLiveView');
  });

  testWidgets('pressing the open tab again hands the keyboard back to it', (
    tester,
  ) async {
    await _pumpPanel(tester, terminals: 3);

    await tester.tap(find.text('Terminal 1'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-1')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'TerminalLiveView');
  });

  testWidgets('Kill hands the keyboard to the neighbour terminal', (
    tester,
  ) async {
    await _pumpPanel(tester, terminals: 3);

    await tester.tap(find.text('Terminal 3'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Kill'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-2')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'TerminalLiveView');
  });

  group('a strip with more terminals than fit', () {
    double stripOffset(WidgetTester tester) => tester
        .state<ScrollableState>(
          find
              .ancestor(
                of: find.text('Terminal 1'),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .pixels;

    testWidgets('desktop pages it with scroll buttons that show only where '
        'there is more', (tester) async {
      await _pumpPanel(tester, terminals: 8, width: 420);
      await tester.pumpAndSettle();
      // The open terminal is the first, so nothing lies to its left yet.
      expect(_scrollButton(CarbonIcons.chevronLeft), findsNothing);
      expect(_scrollButton(CarbonIcons.chevronRight), findsOneWidget);

      await tester.tap(_scrollButton(CarbonIcons.chevronRight));
      await tester.pumpAndSettle();

      expect(stripOffset(tester), greaterThan(0));
      expect(_scrollButton(CarbonIcons.chevronLeft), findsOneWidget);
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

    testWidgets('a vertical mouse wheel scrolls the strip sideways', (
      tester,
    ) async {
      await _pumpPanel(tester, terminals: 8, width: 420);
      await tester.pumpAndSettle();

      final pointer = TestPointer(1, PointerDeviceKind.mouse)
        ..hover(tester.getCenter(find.text('Terminal 1')));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await tester.pump();

      expect(stripOffset(tester), greaterThan(0));
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

    testWidgets('touch shows the same scroll buttons and still swipes', (
      tester,
    ) async {
      await _pumpPanel(tester, terminals: 8, width: 360);
      await tester.pumpAndSettle();
      expect(_scrollButton(CarbonIcons.chevronRight), findsOneWidget);

      await tester.drag(find.text('Terminal 1'), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(stripOffset(tester), greaterThan(0));
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));

    testWidgets('a terminal opened past the edge is scrolled into view', (
      tester,
    ) async {
      await _pumpPanel(tester, terminals: 8, width: 420);

      await tester.tap(find.text('New'));
      // Not pumpAndSettle: the starting tab animates until the start
      // deadline drops it, so settling would outlast the tab itself. The
      // reveal starts after the first frame and its ticker starts the next.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      final strip = tester.getRect(
        find
            .ancestor(
              of: find.text('Terminal 1'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final pill = tester.getRect(find.text('Terminal 9'));
      expect(pill.right, lessThanOrEqualTo(strip.right));
      expect(pill.left, greaterThanOrEqualTo(strip.left));
      await _outlastStartDeadline(tester);
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
  });
}
