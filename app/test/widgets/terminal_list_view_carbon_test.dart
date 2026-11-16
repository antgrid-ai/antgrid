// What the Carbon Terminals tab owes beyond the behaviour the older tests pin:
// no Ab widgets in any of its scopes, no scope around the terminal pane (which
// is Ab and shared with the agent panel), both densities and brightnesses,
// manual tab activation, and the failed and empty panes.
import 'dart:async';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/widgets/terminal_list_view.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;

import '../helpers/carbon_guard.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

Future<FakeAgentTransport> _pump(
  WidgetTester tester, {
  CheckoutAttachStatus? attach,
  int terminals = 2,
  double width = 800,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final session = await newFakeProjectSession(transport, projectId: 'test');
  // Not awaited: see terminal_list_view_empty_state_test.dart.
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
        if (attach != null)
          terminalStateProvider.overrideWith(
            (ref) => Stream.value(TerminalState(attach: attach)),
          ),
      ],
      child: MaterialApp(
        theme:
            (brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light())
                .copyWith(
                  extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
                ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
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
  await tester.pump();
  if (attach == null) {
    transport.emit('agent:status', {
      'projectId': 'test',
      'checkoutPath': '/home/dev/demo-shop',
      'terminals': [
        for (var i = 1; i <= terminals; i++)
          {
            'terminalId': 'terminal-$i',
            'name': 'Terminal $i',
            'running': true,
            'shell': '/bin/zsh',
            'cols': 80,
            'rows': 24,
          },
      ],
    });
    await tester.pump();
    await tester.pump();
  }
  transport.clearSent();
  return transport;
}

/// Every scope the surface mounts must be free of Ab widgets, and none may
/// enclose the terminal pane.
void _expectCleanScopes(WidgetTester tester) {
  final scopes = find.byType(AbCarbonScope);
  expect(scopes, findsWidgets);
  for (var i = 0; i < scopes.evaluate().length; i++) {
    expect(
      abWidgetsInScope(
        tester,
        scope: scopes.at(i),
        allow: {'AbAgentMark', 'AbCarbonScope'},
      ),
      isEmpty,
      reason: 'scope $i',
    );
  }
  expect(
    find.descendant(of: scopes, matching: find.byType(TerminalViewWrapper)),
    findsNothing,
  );
}

// The binding checks its debug overrides before any tearDown runs, so the
// platform override set by [_pump] has to be put back inside the test body.
void testWidgets(String description, Future<void> Function(WidgetTester) body) =>
    ft.testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      final name = '${platform.name}, ${brightness.name}';

      testWidgets('loaded: strip and toolbar hold no Ab widget ($name)', (
        tester,
      ) async {
        await _pump(tester, platform: platform, brightness: brightness);

        expect(find.byType(TerminalViewWrapper), findsOneWidget);
        expect(find.byType(AbCarbonScope), findsNWidgets(2));
        _expectCleanScopes(tester);
      });

      testWidgets('empty: no Ab widget ($name)', (tester) async {
        await _pump(
          tester,
          attach: CheckoutAttachStatus.ready,
          platform: platform,
          brightness: brightness,
        );

        expect(find.text('No terminals running'), findsOneWidget);
        _expectCleanScopes(tester);
      });

      testWidgets('attaching: no Ab widget ($name)', (tester) async {
        await _pump(
          tester,
          attach: CheckoutAttachStatus.attaching,
          platform: platform,
          brightness: brightness,
        );

        expect(find.text('Attaching terminals…'), findsOneWidget);
        _expectCleanScopes(tester);
      });

      testWidgets('failed: no Ab widget ($name)', (tester) async {
        await _pump(
          tester,
          attach: CheckoutAttachStatus.failed,
          platform: platform,
          brightness: brightness,
        );

        expect(find.text("Couldn't load terminals"), findsOneWidget);
        _expectCleanScopes(tester);
      });
    }
  }

  testWidgets('a narrow pane folds the toolbar into a menu with Kill as the '
      'danger item', (tester) async {
    final transport = await _pump(tester, width: 360);
    expect(find.text('Restart'), findsNothing);

    await tester.tap(find.byType(CarbonOverflowMenu));
    await tester.pumpAndSettle();

    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Kill'), findsOneWidget);
    _expectCleanScopes(tester);

    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();
    expect(
      transport.sent.where((m) => m['type'] == 'terminal:start').single['terminalId'],
      'terminal-1',
    );
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('arrow keys move between tabs without opening them until Enter', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('terminal-1')), findsOneWidget);

    Focus.of(tester.element(find.text('Terminal 1'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-2')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-2')), findsOneWidget);
  });

  testWidgets('failed pane at 2.0 text scale scrolls instead of overflowing', (
    tester,
  ) async {
    await _pump(
      tester,
      attach: CheckoutAttachStatus.failed,
      width: 320,
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('New terminal'), findsOneWidget);
  });

  testWidgets('empty pane at 2.0 text scale scrolls instead of overflowing', (
    tester,
  ) async {
    await _pump(
      tester,
      attach: CheckoutAttachStatus.ready,
      width: 320,
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No terminals running'), findsOneWidget);
  });
}
