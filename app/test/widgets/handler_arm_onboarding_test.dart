import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/handler_discovery.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/handler/handler_arm_explainer.dart';
import 'package:antgrid/widgets/handler/handler_away_hint.dart';
import 'package:antgrid/widgets/handler/handler_item_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('handlerArmExplainerBody', () {
    const base =
        "Handler watches this session while you're away. When the agent "
        'pauses on a question or a permission, Handler answers what it safely '
        'can and queues the rest for you.';

    test('observable agent gets no coverage line', () {
      expect(handlerArmExplainerBody(agentObservable: true), base);
    });

    test('unwatchable agent appends the unwatchable notice', () {
      final body = handlerArmExplainerBody(
        agentObservable: false,
        agentLabel: 'Claude Code',
      );
      expect(body, startsWith(base));
      expect(body, contains(unwatchableNotice('Claude Code')));
    });

    test('unknown coverage appends the "may stay silent" line', () {
      final body = handlerArmExplainerBody(agentObservable: null);
      expect(body, startsWith(base));
      expect(
        body,
        contains(
          "This agent hasn't reported what Handler can see here, so it may "
          'stay silent.',
        ),
      );
    });
  });

  group('shieldShowsLabel', () {
    test('labels only before the first arm and never while armed', () {
      expect(shieldShowsLabel(armedOnce: false, sessionArmed: false), isTrue);
      expect(shieldShowsLabel(armedOnce: true, sessionArmed: false), isFalse);
      expect(shieldShowsLabel(armedOnce: false, sessionArmed: true), isFalse);
      expect(shieldShowsLabel(armedOnce: true, sessionArmed: true), isFalse);
    });
  });

  testWidgets('away hint renders its banner and dismiss persists the kill', (
    tester,
  ) async {
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const HandlerAwayHint(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          handlerAwayHintProvider.overrideWith((_) => true),
        ],
      ),
    );
    await tester.pump();

    expect(
      find.text(
        "Still waiting on you — Handler can watch this session and reply "
        "while you're away.",
      ),
      findsOneWidget,
    );
    expect(find.text('ARM'), findsOneWidget);

    await tester.tap(find.byTooltip("Dismiss — won't show again"));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HandlerAwayHint)),
    );
    expect(container.read(firstRunProvider).handlerAwayHintDismissed, isTrue);
    expect(store.read().handlerAwayHintDismissed, isTrue);
  });

  group('HandlerHeaderControl shield form', () {
    List<Override> overrides(FirstRunStore store) => [
      firstRunStoreProvider.overrideWithValue(store),
      activeSessionIdProvider.overrideWith(() => ValueController<String?>('t1')),
      activeSessionProvider.overrideWith((_) => null),
      handlerStateProvider.overrideWith(
        (_) => Stream.value(const HandlerState.initial()),
      ),
    ];

    testWidgets('labeled Handler button before the first arm', (tester) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      await tester.pumpWidget(
        _wrap(const HandlerHeaderControl(), overrides: overrides(store)),
      );
      await tester.pump();
      expect(find.text('Handler'), findsOneWidget);
    });

    testWidgets('collapses to the bare shield once armed anywhere', (
      tester,
    ) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      await store.write(const FirstRunState(handlerArmedOnce: true));
      await tester.pumpWidget(
        _wrap(const HandlerHeaderControl(), overrides: overrides(store)),
      );
      await tester.pump();
      expect(find.text('Handler'), findsNothing);
      expect(find.byTooltip('Arm Handler'), findsOneWidget);
    });
  });
}
