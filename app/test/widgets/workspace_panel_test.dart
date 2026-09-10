// Pins `WorkspacePanel`'s `IndexedStack` children against `WorkspaceView`'s
// ordinals — nothing else in the suite mounts this widget's body, so nothing
// else would catch a tab whose enum member has no matching child (or the
// reverse).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/widgets/session_inbox_panel.dart';
import 'package:antgrid/widgets/workspace_panel.dart';

void main() {
  testWidgets('the inbox tab mounts SessionInboxPanel, not a walk off the '
      'end of the child list', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: WorkspacePanel(
              selectedView: WorkspaceView.inbox,
              onViewSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SessionInboxPanel), findsOneWidget);
  });

  testWidgets('every WorkspaceView ordinal has a matching IndexedStack child', (
    tester,
  ) async {
    // Walks the whole enum, not just inbox: a future append with no child in
    // the same slot is exactly the failure this file exists to catch, and
    // testing only the tab this wave added would miss it again next time.
    for (final view in WorkspaceView.values) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: WorkspacePanel(
                selectedView: view,
                onViewSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'WorkspaceView.$view crashed the IndexedStack',
      );
    }
  });
}
