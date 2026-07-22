// AgentPanel swaps its body between the terminal (PTY) and the chat
// transcript based on the active session's mode (Task 10).
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/screens/terminal_screen.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/agent_transcript_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

SessionEntry _session({required String mode}) => SessionEntry(
  id: 'session-1',
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: mode,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets('AgentPanel shows the transcript for a chat session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          activeSessionProvider.overrideWithValue(_session(mode: 'chat')),
        ],
        child: const MaterialApp(home: Scaffold(body: AgentPanel())),
      ),
    );
    await tester.pump();

    expect(find.byType(AgentTranscriptView), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('AgentPanel shows the terminal for a terminal session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          activeSessionProvider.overrideWithValue(_session(mode: 'terminal')),
        ],
        child: const MaterialApp(home: Scaffold(body: AgentPanel())),
      ),
    );
    await tester.pump();

    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(find.byType(AgentTranscriptView), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });
}
