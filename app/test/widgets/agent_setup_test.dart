import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/providers/agent_setup.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/widgets/agent_setup.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

const _codex = AgentDescriptor(
  tool: 'codex',
  label: 'Codex',
  chatCapable: true,
  judgeCapable: true,
  handlerTerminal: true,
  handlerChat: true,
  installUrl: 'https://developers.openai.com/codex/cli/',
);

Widget _host(Widget child, List<Override> overrides) => ProviderScope(
  overrides: [
    agentSetupCatalogProvider.overrideWithValue([_codex]),
    ...overrides,
  ],
  child: MaterialApp(
    theme: buildAbTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets(
    'setup opens installation guidance and hides advanced troubleshooting',
    (tester) async {
      await tester.pumpWidget(
        _host(const AgentSetupHelp(), [
          localDetectedToolsProvider.overrideWith((_) async => {}),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('refresh its environment'), findsNothing);
      await tester.tap(find.text('Set up a coding agent'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentSetupDialog), findsOneWidget);
      expect(find.text('Codex installation guide'), findsOneWidget);
      expect(find.textContaining('finish signing in'), findsOneWidget);
      // The setup dialog must not recursively offer another setup dialog.
      expect(
        find.widgetWithText(AbButton, 'Set up a coding agent').hitTestable(),
        findsNothing,
      );
    },
  );

  testWidgets(
    'guide uses the advertised URL and identifies the install machine',
    (tester) async {
      String? opened;
      await tester.pumpWidget(
        _host(
          AgentSetupDialog(
            machine: (uuid: 'work', label: 'Work laptop'),
            openUrl: (_, url) async {
              opened = url;
            },
          ),
          [
            agentSetupMachineProvider.overrideWithValue((
              uuid: 'work',
              label: 'Work laptop',
            )),
            agentSetupToolsProvider.overrideWithValue(const AsyncData({})),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Install one agent on Work laptop'),
        findsOneWidget,
      );
      await tester.tap(find.text('Codex installation guide'));
      await tester.pump();
      expect(opened, _codex.installUrl);
    },
  );

  testWidgets('retry remains focused while scanning and announces success', (
    tester,
  ) async {
    final scan = Completer<Map<String, String?>>();
    var attempts = 0;
    await tester.pumpWidget(
      _host(const AgentSetupHelp(), [
        localDetectedToolsProvider.overrideWith((_) {
          attempts++;
          return attempts == 1 ? Future.value({}) : scan.future;
        }),
      ]),
    );
    await tester.pumpAndSettle();
    final retry = find.byKey(const ValueKey('agent-setup-retry'));
    final focusable = find.descendant(
      of: retry,
      matching: find.byType(FocusableActionDetector),
    );
    final focus = Focus.of(
      tester.element(
        find
            .descendant(of: focusable, matching: find.byType(GestureDetector))
            .first,
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.tap(find.text('Check again'));
    await tester.pump();
    expect(find.text('Checking…'), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    scan.complete({'codex': 'Codex'});
    await tester.pumpAndSettle();
    expect(find.text('Codex detected on this computer.'), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.text('Codex detected on this computer.'),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .liveRegion,
      isTrue,
    );
  });

  testWidgets(
    'choosing another computer leaves no stale local project selected',
    (tester) async {
      await tester.pumpWidget(
        _host(const AgentSetupHelp(), [
          localDetectedToolsProvider.overrideWith((_) async => {}),
          pickerSourcesProvider.overrideWithValue(const [
            PickerSource(
              id: 'local',
              label: 'Local',
              isLocal: true,
              projects: [],
            ),
            PickerSource(
              id: 'machine:work',
              label: 'Work laptop',
              isLocal: false,
              projects: [],
              machineUuid: 'work',
            ),
          ]),
          remoteDetectedToolsProvider(
            'work',
          ).overrideWithValue(const AsyncData({'codex': 'Codex'})),
        ]),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AgentSetupHelp)),
      );
      container
          .read(selectedTargetProjectProvider.notifier)
          .set(
            const PickerProject(
              id: 'local-project',
              name: 'Local project',
              detail: '',
              isLocal: true,
            ),
          );
      await tester.tap(find.text('Use another computer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work laptop'));
      await tester.pump();
      expect(container.read(selectedSourceIdProvider), 'machine:work');
      expect(container.read(selectedTargetProjectProvider), isNull);
    },
  );
}
