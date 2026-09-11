// Pins `WorkspacePanel`'s `IndexedStack` children against `WorkspaceView`'s
// ordinals — nothing else in the suite mounts this widget's body, so nothing
// else would catch a tab whose enum member has no matching child (or the
// reverse).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/widgets/workspace_panel.dart';

void main() {
  testWidgets('every WorkspaceView ordinal has a matching IndexedStack child', (
    tester,
  ) async {
    // Walks the whole enum rather than the view a change happens to touch: an
    // append with no child in the same slot, or a removal that leaves one
    // behind, is exactly the failure this file exists to catch.
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
