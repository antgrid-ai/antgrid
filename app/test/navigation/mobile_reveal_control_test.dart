// A phone has no workspace menu — the workspace is the page one swipe over —
// so anything that reveals a view must go through the shell's own reveal
// control. Called through the menu instead, a link tap on a phone does nothing.
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  testWidgets('a phone reveals a view through the shell, not the menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      final c = await pumpWorkspaceShell(tester);
      await settleShell(tester);
      expect(c.read(workspaceMenuControlProvider), isNull);
      expect(find.text('Files').hitTestable(), findsNothing);

      c.read(revealWorkspaceViewControlProvider)!(WorkspaceView.files);
      await settleShell(tester);

      expect(c.read(visibleWorkspaceViewProvider), WorkspaceView.files);
      expect(find.text('Files').hitTestable(), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
