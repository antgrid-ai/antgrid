import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/open_checkout.dart';
import 'package:antgrid/widgets/session_memory_restart_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEntry _session({bool flagged = true, bool running = true}) =>
    SessionEntry(
      id: 's1',
      name: 'Session',
      createdAt: 0,
      lastUsedAt: 0,
      archived: false,
      running: running,
      startedWithoutMemory: flagged,
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required SessionEntry session,
    bool local = true,
    bool memoryOn = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          entryIsLocalCheckoutProvider.overrideWith((ref, id) async => local),
          memoryDrawerEnabledProvider.overrideWith((ref) async => memoryOn),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: SessionMemoryRestartBadge(entryId: 'proj', session: session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders for a flagged local session with Memory on', (
    tester,
  ) async {
    await pump(tester, session: _session());
    expect(find.byType(AbChip), findsOneWidget);
    expect(find.text('NO MEMORY'), findsOneWidget);
  });

  testWidgets('is absent for an entry that is not a local checkout', (
    tester,
  ) async {
    await pump(tester, session: _session(), local: false);
    expect(find.byType(AbChip), findsNothing);
  });

  testWidgets('is absent when the session is not flagged', (tester) async {
    await pump(tester, session: _session(flagged: false));
    expect(find.byType(AbChip), findsNothing);
  });

  testWidgets('is absent for a stopped session that is still flagged', (
    tester,
  ) async {
    await pump(tester, session: _session(running: false));
    expect(find.byType(AbChip), findsNothing);
  });

  testWidgets('is absent while Memory is off', (tester) async {
    await pump(tester, session: _session(), memoryOn: false);
    expect(find.byType(AbChip), findsNothing);
  });
}
