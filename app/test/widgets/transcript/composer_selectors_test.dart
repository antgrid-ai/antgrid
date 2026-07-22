import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/composer_selectors.dart';

const _caps = AgentCapabilities(
  sessionId: 's1',
  models: [
    AgentCapabilityModel(
      id: 'gpt-5.2',
      name: 'GPT-5.2',
      efforts: ['low', 'high'],
    ),
    AgentCapabilityModel(id: 'gpt-5.2-mini', name: 'GPT-5.2 Mini'),
  ],
  modes: [
    AgentCapabilityMode(id: ':workspace', name: ':workspace'),
    AgentCapabilityMode(id: ':readonly', name: ':readonly'),
  ],
  currentModelId: 'gpt-5.2',
  currentEffortId: 'high',
  currentModeId: ':workspace',
);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders MODEL, EFFORT, and MODE pills from capabilities', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(ComposerSelectors(capabilities: _caps, onSetConfig: (_, _) {})),
    );
    // AbChip.toggle renders labels uppercased; mode/effort ids are
    // stripped of their leading ":" and title-cased for display.
    expect(find.text('GPT-5.2'), findsOneWidget);
    expect(find.text('HIGH'), findsOneWidget);
    expect(find.text('WORKSPACE'), findsOneWidget);
  });

  testWidgets('renders nothing when capabilities are empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ComposerSelectors(
          capabilities: const AgentCapabilities(sessionId: 's1'),
          onSetConfig: (_, _) {},
        ),
      ),
    );
    // Scaffold internals contain SizedBoxes of their own — assert on the
    // absence of pills, not on the shrink box itself.
    expect(find.byType(AbChip), findsNothing);
  });

  testWidgets('hides EFFORT when the current model has no efforts', (
    tester,
  ) async {
    const caps = AgentCapabilities(
      sessionId: 's1',
      models: [AgentCapabilityModel(id: 'm1', name: 'Plain')],
      currentModelId: 'm1',
    );
    await tester.pumpWidget(
      _wrap(ComposerSelectors(capabilities: caps, onSetConfig: (_, _) {})),
    );
    expect(find.text('PLAIN'), findsOneWidget);
    expect(find.text('EFFORT'), findsNothing);
  });

  testWidgets('picking a menu entry fires onSetConfig with the id', (
    tester,
  ) async {
    String? gotKey;
    String? gotValue;
    await tester.pumpWidget(
      _wrap(
        ComposerSelectors(
          capabilities: _caps,
          onSetConfig: (k, v) {
            gotKey = k;
            gotValue = v;
          },
        ),
      ),
    );
    await tester.tap(find.text('GPT-5.2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-5.2 Mini'));
    await tester.pumpAndSettle();
    expect(gotKey, 'model');
    expect(gotValue, 'gpt-5.2-mini');
  });

  testWidgets(
    'title-cases hyphenated mode ids and strips the colon prefix for display, '
    'but sends the raw id to onSetConfig',
    (tester) async {
      String? gotKey;
      String? gotValue;
      const caps = AgentCapabilities(
        sessionId: 's1',
        modes: [
          AgentCapabilityMode(
            id: ':danger-full-access',
            name: ':danger-full-access',
          ),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          ComposerSelectors(
            capabilities: caps,
            onSetConfig: (k, v) {
              gotKey = k;
              gotValue = v;
            },
          ),
        ),
      );
      await tester.tap(find.text('MODE'));
      await tester.pumpAndSettle();
      expect(find.text('Danger Full Access'), findsOneWidget);
      await tester.tap(find.text('Danger Full Access'));
      await tester.pumpAndSettle();
      expect(gotKey, 'mode');
      expect(gotValue, ':danger-full-access');
    },
  );
}
