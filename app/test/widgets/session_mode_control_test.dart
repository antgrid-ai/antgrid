// The Chat cell of the in-session mode switch: what an unanswered capability
// does to it, and the one thing that outranks the answer.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/focused_tools.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/widgets/mode_segmented.dart';
import 'package:antgrid/widgets/session_mode_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

SessionEntry _session({required String mode, String? tool}) => SessionEntry(
  id: 'session-1',
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: mode,
  tool: tool,
);

Future<ModeSegmented> _pumpControl(
  WidgetTester tester, {
  required SessionEntry session,
  required bool? chatCapable,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeSessionProvider.overrideWithValue(session),
        focusedMachineToolsProvider.overrideWith(
          (ref) async => const FocusedTools(),
        ),
        focusedToolChatCapableProvider(
          session.tool,
        ).overrideWith((ref) => chatCapable),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: SessionModeControl())),
      ),
    ),
  );
  await tester.pump();
  return tester.widget<ModeSegmented>(find.byType(ModeSegmented));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets('a session running in chat mode is never chat-incapable', (
    tester,
  ) async {
    // Proof by existence outranks the advert: greying the cell the session is
    // sitting in would say the mode on screen is impossible.
    final control = await _pumpControl(
      tester,
      session: _session(mode: 'chat', tool: 'kilo'),
      chatCapable: null,
    );
    expect(control.chatEnabled, isTrue);
  });

  testWidgets('an unanswered capability blames neither the agent nor the '
      'bridge alone', (tester) async {
    // The same null covers a machine that hasn't reported yet and a bridge too
    // old to carry the field; only the second is the user's to fix.
    final control = await _pumpControl(
      tester,
      session: _session(mode: 'terminal', tool: 'kilo'),
      chatCapable: null,
    );
    expect(control.chatEnabled, isFalse);
    expect(control.chatDisabledReason, contains("hasn't said"));
    expect(control.chatDisabledReason, contains('still be connecting'));
  });

  testWidgets('a described incapable agent names the agent', (tester) async {
    final control = await _pumpControl(
      tester,
      session: _session(mode: 'terminal', tool: 'kilo'),
      chatCapable: false,
    );
    expect(control.chatEnabled, isFalse);
    expect(control.chatDisabledReason, "kilo doesn't support chat sessions.");
  });
}
