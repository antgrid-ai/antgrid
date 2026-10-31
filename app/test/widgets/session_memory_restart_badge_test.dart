import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/widgets/session_memory_restart_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEntry _session({bool running = true, bool flagged = true}) =>
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
    String entryId = 'proj',
    bool memoryOn = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryDrawerEnabledProvider.overrideWith((ref) async => memoryOn),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: SessionMemoryRestartBadge(entryId: entryId, session: session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders for a flagged, running, local session with Memory on', (
    tester,
  ) async {
    await pump(tester, session: _session());
    expect(find.byType(AbChip), findsOneWidget);
    expect(find.text('NO MEMORY'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('is absent for a remote entry id', (tester) async {
    await pump(tester, session: _session(), entryId: 'machine-1.proj');
    expect(find.byType(AbChip), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('is absent when the session is not flagged or not running', (
    tester,
  ) async {
    await pump(tester, session: _session(flagged: false));
    expect(find.byType(AbChip), findsNothing);
    await pump(tester, session: _session(running: false));
    expect(find.byType(AbChip), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('is absent while Memory is off', (tester) async {
    await pump(tester, session: _session(), memoryOn: false);
    expect(find.byType(AbChip), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('is absent on mobile', (tester) async {
    await pump(tester, session: _session());
    expect(find.byType(AbChip), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
