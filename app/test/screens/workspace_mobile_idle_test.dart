// app/test/screens/workspace_mobile_idle_test.dart
//
// The mobile layout must go quiet once it has drawn. `_buildMobile` registers
// its surface-publish post-frame callback on EVERY build and the publish is
// unconditional, so the shell only stops if re-publishing a value that is
// already there notifies nobody. That makes `SessionWorkspaceState`'s value
// equality load-bearing: without it the publish wakes `_syncSessionUi`'s watch,
// the rebuild registers the callback again, and the shell rebuilds every frame
// for as long as the project is open.
//
// The rest of the mobile suite cannot see this. The shell always has something
// animating, so those tests pump a bounded number of frames instead of
// settling, and a rebuild loop looks exactly like a cursor blink to them.
// Counting PROVIDER emissions rather than builds is what makes it visible: a
// rebuild from any other cause still republishes an equal value and is silent.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/session_workspace_state.dart';
import 'package:antgrid/providers/sessions.dart' show sessionsStateProvider;
import 'package:antgrid/services/sessions_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  testWidgets('an idle mobile layout republishes nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // A focused session is what arms the publish at all: with no key
    // `_updateSessionUi` returns before it writes, so an empty project cannot
    // reach the loop this test is about. It has to come from the live stream —
    // the cached list feeds the drawer, not `activeSessionIdProvider`.
    final container = await pumpWorkspaceShell(
      tester,
      extraOverrides: [
        sessionsStateProvider.overrideWith(
          (ref) => Stream.value(
            const SessionsState(
              projectId: testAgentDeviceId,
              sessions: [
                SessionEntry(
                  id: 'session-1',
                  name: 'one',
                  createdAt: 1,
                  lastUsedAt: 1,
                  archived: false,
                  running: false,
                ),
              ],
            ),
          ),
        ),
      ],
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    final key = container.read(activeSessionUiKeyProvider);
    expect(key, isNotNull, reason: 'nothing is published without a session');

    var emits = 0;
    final sub = container.listen(
      sessionWorkspaceStateProvider(key!),
      (_, _) => emits++,
    );
    addTearDown(sub.close);

    // Idle: no gesture, no wire traffic, nothing but frames.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugDefaultTargetPlatformOverride = null;

    expect(
      emits,
      0,
      reason: 'the shell is driving its own rebuilds',
    );
  });
}
