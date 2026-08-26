// DemoFrame is mounted from `MaterialApp.builder`, which makes everything it
// draws a SIBLING of the app's Navigator rather than a descendant. That is the
// whole point (the strip survives every pushed route) and it is also the trap:
// the Navigator owns the app's only Overlay, so any chrome the frame mounts is
// on its own. These run the frame on Windows, the one platform where it draws
// caption buttons — no other demo test overrides the platform, which is why a
// missing Overlay reached a real window instead of a red test.
import 'dart:async';

import 'package:antgrid/design/widgets/ab_window_controls.dart';
import 'package:antgrid/navigation/root_navigator.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/screens/sign_in_screen.dart';
import 'package:antgrid/widgets/demo_frame.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

/// Runs [body] as a Windows desktop window.
///
/// The platform override is undone in a `finally` rather than an `addTearDown`:
/// the binding asserts every foundation debug variable is back to its default
/// at the END OF THE TEST BODY, which is before tear-downs run.
Future<void> _onWindowsDesktop(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // The real surface, not just MediaQuery: the frame's chrome lays out
    // against the view, so a desktop MediaQuery over the default 800x600 view
    // overflows the shell and buries the assertion we care about.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the demo window chrome on Windows', () {
    testWidgets('builds its caption buttons without an error widget', (
      tester,
    ) async {
      await _onWindowsDesktop(tester, () async {
        await pumpDemoApp(tester, enterDemo: true, size: const Size(1400, 900));
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(find.byType(DemoFrame), findsOneWidget);
        expect(find.byType(AbWindowControls), findsOneWidget);
      });
    });
  });

  group('a route pushed inside the demo', () {
    testWidgets('does not outlive Exit demo', (tester) async {
      final container = await pumpDemoApp(tester, enterDemo: true);
      await tester.pump(const Duration(milliseconds: 100));

      // Pushed straight onto the app's Navigator rather than through a real
      // affordance: the demo's only modal is behind a Ctrl/Cmd-K binding no
      // touch device can reach, and what is under test is the route stack, not
      // whatever happens to fill it.
      final navigator = container.read(rootNavigatorKeyProvider).currentState!;
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Text('demo modal')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('demo modal'), findsOneWidget);
      expect(navigator.canPop(), isTrue);

      exitDemoMode(container);

      // Unwinding the stack is synchronous; only the exit transition is
      // animated. Asserted before any pump for exactly that reason — it is the
      // invariant, and the frames below are just the modal finishing leaving.
      expect(navigator.canPop(), isFalse);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Reparenting alone would have carried it across — `WidgetsApp` keys its
      // Navigator with a GlobalKey — leaving a demo modal over the real app.
      expect(find.text('demo modal'), findsNothing);
      expect(find.byType(SignInScreen), findsOneWidget);
    });
  });
}
