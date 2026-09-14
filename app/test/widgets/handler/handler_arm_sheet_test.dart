// The last screen before a user stops watching a session. What is pinned here
// is the sheet's ACCOUNT OF ITSELF: that it names its own subject even on the
// repeat arm where every explanatory sentence has been retired, and that the
// sentence it says the backlog starts from is one the user can actually see.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/handler/handler_arm_explainer.dart';
import 'package:antgrid/widgets/handler/handler_item_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

const _blockHead = "WHAT TO DO WHILE YOU'RE AWAY";

/// The machine that has named its lenses, so the lens row renders live rather
/// than inert. Nothing here turns on which lenses those are.
HandlerState _state() => const HandlerState(
  lenses: ['pm', 'qa', 'critic', 'release'],
  sessions: {},
  escalations: [],
  activity: [],
);

/// Opens the real sheet the way [armWithSheet] does. [explain] false with a
/// watchable agent is the ORDINARY repeat arm — the state whose explanatory
/// body is null, and which used to leave the sheet with nothing but a title
/// over an unlabelled box.
Future<void> _pumpSheet(
  WidgetTester tester, {
  String? openingPrompt,
  bool explain = false,
  bool? agentObservable = true,
  String? agentLabel = 'Claude Code',
}) async {
  useInMemoryPrefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        handlerStateProvider.overrideWith((ref) => Stream.value(_state())),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () => showHandlerArmSheet(
                  context,
                  terminalId: 't1',
                  initial: (judgeTool: null, judgeModel: null, lens: null),
                  agentObservable: agentObservable,
                  agentLabel: agentLabel,
                  openingPrompt: openingPrompt,
                  explain: explain,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('the sheet names its subject', () {
    testWidgets('on the repeat arm, where every explanation is retired', (
      tester,
    ) async {
      await _pumpSheet(tester);

      // The state this heading exists for: no body paragraph at all, so the
      // heading is the only thing between the title and an empty box.
      expect(
        handlerArmExplainerBody(agentObservable: true, explain: false),
        isNull,
      );
      expect(find.text(_blockHead), findsOneWidget);
    });

    testWidgets('and on the first arm, above the explanation it repeats', (
      tester,
    ) async {
      await _pumpSheet(tester, explain: true);

      expect(find.text(_blockHead), findsOneWidget);
    });
  });

  group('the goal the backlog starts from', () {
    testWidgets('is shown, not referred to', (tester) async {
      await _pumpSheet(tester, openingPrompt: 'fix the login redirect');

      expect(
        find.text('Your backlog starts with: fix the login redirect'),
        findsOneWidget,
      );
      // The hint the quote is the antecedent for.
      expect(find.text('Anything to add beyond that?'), findsOneWidget);
    });

    testWidgets('is absent when the session was opened from nothing', (
      tester,
    ) async {
      await _pumpSheet(tester);

      expect(find.textContaining('Your backlog starts with'), findsNothing);
      expect(
        find.text("Add what you want done while you're away."),
        findsOneWidget,
      );
    });

    testWidgets('is not a line of whitespace', (tester) async {
      // A remembered prompt is whatever the New Session composer was sent
      // with. Quoting blanks would leave a bare label over a composer asking
      // what to add "beyond that".
      await _pumpSheet(tester, openingPrompt: '   \n  ');

      expect(find.textContaining('Your backlog starts with'), findsNothing);
      expect(
        find.text("Add what you want done while you're away."),
        findsOneWidget,
      );
    });

    testWidgets('is trimmed of the whitespace around it', (tester) async {
      await _pumpSheet(tester, openingPrompt: '  ship the parser  ');

      expect(
        find.text('Your backlog starts with: ship the parser'),
        findsOneWidget,
      );
    });

    testWidgets('is withheld from an agent that cannot be watched', (
      tester,
    ) async {
      // Extraction still runs, so the sentence is mechanically true — but the
      // notice directly above says arming this agent stays silent, and a
      // backlog promised over that is the one claim the sheet must not make.
      await _pumpSheet(
        tester,
        openingPrompt: 'fix the login redirect',
        agentObservable: false,
        explain: true,
      );

      expect(find.textContaining('Your backlog starts with'), findsNothing);
      expect(
        find.textContaining(unwatchableNotice('Claude Code')),
        findsOneWidget,
      );
      // And the composer stops asking what to add "beyond that", since the
      // sheet has named nothing for "that" to refer to.
      expect(
        find.text("Add what you want done while you're away."),
        findsOneWidget,
      );
    });
  });
}
