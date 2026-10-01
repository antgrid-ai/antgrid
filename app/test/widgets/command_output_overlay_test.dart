import 'dart:async';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/command_output_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _focus = NotifierProvider<ValueController<String>, String>(
  () => ValueController<String>('a'),
);

CommandState _state(CommandStatus status, String output) => CommandState(
  current: CommandExecution(
    commandName: 'test',
    projectId: 'p',
    status: status,
    output: ValueNotifier(output),
  ),
);

void main() {
  // The provider follows focus, so states before and after a checkout switch
  // are two commands; reading them as one would dismiss the landed result.
  testWidgets('a checkout switch is not read as a command finishing', (
    tester,
  ) async {
    final a = StreamController<CommandState>.broadcast();
    final b = StreamController<CommandState>.broadcast();
    addTearDown(a.close);
    addTearDown(b.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commandStateProvider.overrideWith(
            (ref) => ref.watch(_focus) == 'a' ? a.stream : b.stream,
          ),
          selectedRegistrationIdProvider.overrideWithValue('p'),
          focusedCheckoutIdProvider.overrideWith((ref) => ref.watch(_focus)),
          terminalStateProvider.overrideWith(
            (ref) => const Stream<TerminalState>.empty(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
          ),
          home: const Scaffold(
            body: Stack(children: [CommandOutputOverlay()]),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CommandOutputOverlay)),
    );

    a.add(_state(CommandStatus.running, 'a is building'));
    await tester.pump();
    await tester.pump();
    expect(find.text('a is building'), findsOneWidget);

    container.read(_focus.notifier).set('b');
    await tester.pump();
    b.add(_state(CommandStatus.success, 'b finished long ago'));
    await tester.pump();
    await tester.pump();

    // Still expanded: nothing finished in front of the user.
    expect(find.text('b finished long ago'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('b finished long ago'), findsOneWidget);
  });
}
