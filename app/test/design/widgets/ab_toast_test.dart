import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_tap_target.dart';
import 'package:antgrid/design/widgets/ab_toast.dart';

import '../test_harness.dart';

/// Moves a mouse pointer over [finder] and settles — the close button only
/// reveals on a genuine hover event, not just because it's in the tree.
Future<void> _hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: tester.getCenter(finder));
  await tester.pump();
}

/// Runs [body] under [platform], clearing the override before returning —
/// the binding asserts every foundation debug variable is unset BEFORE
/// tearDown runs, so clearing it there (rather than inside the test body) is
/// too late. Mirrors `notification_toast_action_test.dart`'s `_withShell`.
Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets('renders title and desc', (tester) async {
    await pumpAntgrid(
      tester,
      const AbToast(
        icon: AbIcons.check,
        title: 'Session committed',
        description: '14 files · feat/auth-flow',
      ),
    );
    expect(find.text('Session committed'), findsOneWidget);
    expect(find.text('14 files · feat/auth-flow'), findsOneWidget);
  });

  testWidgets('action button fires onAction', (tester) async {
    var clicked = false;
    await pumpAntgrid(
      tester,
      AbToast(
        icon: AbIcons.check,
        title: 'x',
        description: 'y',
        actionLabel: 'Open PR',
        onAction: () => clicked = true,
      ),
    );
    await tester.tap(find.text('Open PR'));
    expect(clicked, isTrue);
  });

  testWidgets('renders no close button without onClose', (tester) async {
    await pumpAntgrid(tester, const AbToast(icon: AbIcons.check, title: 'x'));
    expect(find.byTooltip('Dismiss'), findsNothing);
  });

  testWidgets('desktop close button is present but not hit-testable before '
      'hover', (tester) async {
    await _withPlatform(TargetPlatform.windows, () async {
      var closed = false;
      await pumpAntgrid(
        tester,
        AbToast(icon: AbIcons.check, title: 'x', onClose: () => closed = true),
      );
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      // Not hovered yet: the button sits at opacity 0 behind an IgnorePointer,
      // so a tap here must not reach it.
      await tester.tap(find.byTooltip('Dismiss'), warnIfMissed: false);
      expect(closed, isFalse);
    });
  });

  testWidgets('desktop close button fires onClose once hovered', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.windows, () async {
      var closed = false;
      await pumpAntgrid(
        tester,
        AbToast(icon: AbIcons.check, title: 'x', onClose: () => closed = true),
      );
      await _hover(tester, find.byType(AbToast));
      await tester.tap(find.byTooltip('Dismiss'));
      expect(closed, isTrue);
    });
  });

  testWidgets('renders no close button on a touch platform, even with '
      'onClose', (tester) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      await pumpAntgrid(
        tester,
        AbToast(icon: AbIcons.check, title: 'x', onClose: () {}),
      );
      expect(find.byTooltip('Dismiss'), findsNothing);
    });
  });

  testWidgets('overlay: close button dismisses the toast immediately', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.windows, () async {
      late BuildContext ctx;
      await pumpAntgrid(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      );

      showAbToast(ctx, 'Path copied');
      await tester.pump();
      expect(find.text('Path copied'), findsOneWidget);

      // Well before the 4s default duration — proves the close button, not
      // the timer, is what took it down.
      await _hover(tester, find.byType(AbToast));
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.text('Path copied'), findsNothing);
    });
  });

  testWidgets('overlay: a burst is capped, dropping the oldest toasts', (
    tester,
  ) async {
    late BuildContext ctx;
    await pumpAntgrid(
      tester,
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        },
      ),
    );

    for (var i = 0; i < 10; i++) {
      showAbToast(ctx, 'toast $i');
    }
    await tester.pump();

    expect(find.byType(AbToast), findsNWidgets(4));
    expect(find.text('toast 9'), findsOneWidget);
    expect(find.text('toast 0'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('overlay: hovering holds the timer, leaving restarts it', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.windows, () async {
      late BuildContext ctx;
      await pumpAntgrid(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      );

      showAbToast(ctx, 'Path copied');
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(
        location: tester.getCenter(find.byType(AbToast)),
      );
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Path copied'), findsOneWidget);

      await gesture.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Path copied'), findsNothing);
    });
  });

  testWidgets('overlay: keyboard focus reveals the close button', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.windows, () async {
      late BuildContext ctx;
      await pumpAntgrid(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      );

      showAbToast(ctx, 'Path copied');
      await tester.pump();
      double closeOpacity() => tester
          .widget<Opacity>(
            find.ancestor(
              of: find.byTooltip('Dismiss'),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      expect(closeOpacity(), 0);

      // Programmatic, not Tab: the root-overlay toast sits outside every
      // route's focus scope, so route traversal never reaches it.
      final inner = find.descendant(
        of: find.byTooltip('Dismiss'),
        matching: find.byType(AbTapTarget),
      );
      Focus.of(tester.element(inner)).requestFocus();
      await tester.pump();
      await tester.pump();
      expect(closeOpacity(), 1);
    });
  });

  testWidgets('overlay: dismisses on its own action tap', (tester) async {
    await _withPlatform(TargetPlatform.windows, () async {
      late BuildContext ctx;
      var acted = false;
      await pumpAntgrid(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      );

      showAbToastOverlay(
        ctx,
        toast: AbToast(
          icon: AbIcons.check,
          title: 'Session committed',
          actionLabel: 'View PR',
          onAction: () => acted = true,
        ),
        duration: const Duration(seconds: 8),
      );
      await tester.pump();
      expect(find.text('View PR'), findsOneWidget);

      await tester.tap(find.text('View PR'));
      await tester.pump();

      expect(acted, isTrue);
      // Gone well inside the 8s duration — the tap dismissed it, not a timer.
      expect(find.text('Session committed'), findsNothing);
    });
  });

  testWidgets('touch: a fling dismisses the toast well before its timer', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      late BuildContext ctx;
      await pumpAntgrid(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      );

      showAbToast(ctx, 'Copied to clipboard');
      await tester.pump();
      expect(find.text('Copied to clipboard'), findsOneWidget);

      await tester.fling(find.byType(AbToast), const Offset(-300, 0), 1000);
      // The exit animation runs on a short delayed Future, not a pump-driven
      // animation — advance real time past it rather than pumpAndSettle.
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Copied to clipboard'), findsNothing);
    });
  });

  testWidgets('touch: a short drag that falls short springs back, not '
      'dismissed', (tester) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      late BuildContext ctx;
      await pumpAntgrid(
        tester,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      );

      showAbToast(ctx, 'Copied to clipboard');
      await tester.pump();

      // Well under the 80px commit distance and too slow to fling.
      await tester.drag(find.byType(AbToast), const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Copied to clipboard'), findsOneWidget);
    });
  });
}
