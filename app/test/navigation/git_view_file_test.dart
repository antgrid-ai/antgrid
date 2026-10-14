// View file in a Git diff opens the file in the Files tab and brings that tab
// forward, in every layout, rather than showing it inside the Git tab.
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  Future<ProviderContainer> openDiff(
    WidgetTester tester, {
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = await pumpWorkspaceShell(
      tester,
      fileTreeStates: Stream.value(
        const FileTreeState(
          git: GitPaneState(
            diffPath: 'a.dart',
            diffContent: '@@ -1 +1 @@\n-old\n+new\n',
            diffAdditions: 1,
            diffDeletions: 1,
          ),
        ),
      ),
    );
    await settleShell(tester);
    // A phone reaches the workspace one page over; a wide layout docks it.
    if (find.byType(PageView).evaluate().isNotEmpty) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await settleShell(tester);
    }
    await tester.tap(find.text('Git').last);
    await settleShell(tester);
    expect(c.read(visibleWorkspaceViewProvider), WorkspaceView.git);
    return c;
  }

  Future<void> tapViewFile(WidgetTester tester) async {
    final viewFile = find.byTooltip('View file').evaluate().isNotEmpty
        ? find.byTooltip('View file')
        : find.text('View file');
    await tester.tap(viewFile.first);
    await settleShell(tester);
  }

  testWidgets('a phone switches to the Files tab', (tester) async {
    final c = await openDiff(tester, size: const Size(400, 800));

    await tapViewFile(tester);

    expect(c.read(visibleWorkspaceViewProvider), WorkspaceView.files);
  });

  testWidgets('a desktop window switches to the Files tab', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final c = await openDiff(tester, size: const Size(1400, 900));

      await tapViewFile(tester);

      expect(c.read(visibleWorkspaceViewProvider), WorkspaceView.files);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The queued-navigation handover waits for a pending session id to resolve;
  // a tap on a workspace that is already open must not.
  testWidgets('the tab switches while a session id is still queued', (
    tester,
  ) async {
    final c = await openDiff(tester, size: const Size(400, 800));
    c.read(pendingActiveSessionIdProvider.notifier).set('queued-session');
    await settleShell(tester);

    await tapViewFile(tester);

    expect(c.read(visibleWorkspaceViewProvider), WorkspaceView.files);
    c.read(pendingActiveSessionIdProvider.notifier).set(null);
  });
}
