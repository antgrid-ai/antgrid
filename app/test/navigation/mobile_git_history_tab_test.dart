// The phone's Git tab splits Changes and History behind a toggle that only
// exists while there are changes. An agent editing and committing in a loop
// moves the change count across zero over and over; the user's choice of
// History must survive every crossing.
import 'dart:async';

import 'package:antgrid/models/file_tree_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  testWidgets('History stays chosen while the change count crosses zero', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final states = StreamController<FileTreeState>();
    addTearDown(states.close);
    states.add(oneChangeTree());
    try {
      await pumpWorkspaceShell(tester, fileTreeStates: states.stream);
      await settleShell(tester);
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await settleShell(tester);
      await tester.tap(find.text('Git').last);
      await settleShell(tester);
      expect(find.text('a.dart').hitTestable(), findsOneWidget);

      // Segments paint upper-case; History's own header is offstage until then.
      await tester.tap(find.text('HISTORY').hitTestable().first);
      await settleShell(tester);
      expect(find.text('a.dart').hitTestable(), findsNothing);

      // A commit empties the tree, then the agent's next edit refills it.
      states.add(const FileTreeState());
      await settleShell(tester);
      expect(find.textContaining('CHANGES ·'), findsNothing);
      states.add(oneChangeTree());
      await settleShell(tester);

      expect(find.textContaining('CHANGES ·'), findsOneWidget);
      expect(find.text('a.dart').hitTestable(), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
