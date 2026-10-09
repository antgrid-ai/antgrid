import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_tap_target.dart';
import 'package:antgrid/design/widgets/ab_toast.dart';

import '../../helpers/hover.dart';
import '../test_harness.dart';

// TargetPlatformVariant (not a manual debugDefaultTargetPlatformOverride)
// because the test binding asserts the override is back to null before the
// test body ends; the variant handles set/restore at the right lifecycle
// points. See test/design/ab_tap_target_test.dart.
const _desktop = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
});
const _touch = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.iOS});

/// Pumps an empty page and returns a route context under the [AbToastHost].
Future<BuildContext> _pumpHost(WidgetTester tester) async {
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
  return ctx;
}

/// Sizes the test view in logical pixels (device pixel ratio 1) so rects read
/// as the window's own coordinates.
void _sizeView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// Pumps an app whose [AbToastHost] wraps a Column holding a widget ABOVE the
/// Navigator and the Navigator itself, returning a context from each side.
Future<({BuildContext above, BuildContext route})> _pumpSplitContexts(
  WidgetTester tester,
) async {
  late BuildContext above;
  late BuildContext route;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      builder: (context, child) => AbToastHost(
        child: Column(
          children: [
            Builder(
              builder: (context) {
                above = context;
                return const SizedBox.shrink();
              },
            ),
            Expanded(child: child!),
          ],
        ),
      ),
      home: Builder(
        builder: (context) {
          route = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return (above: above, route: route);
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
  }, variant: _desktop);

  testWidgets('desktop close button fires onClose once hovered', (
    tester,
  ) async {
    var closed = false;
    await pumpAntgrid(
      tester,
      AbToast(
        icon: AbIcons.check,
        title: 'x',
        onClose: () => closed = true,
        hovered: true,
      ),
    );
    await tester.tap(find.byTooltip('Dismiss'));
    expect(closed, isTrue);
  }, variant: _desktop);

  testWidgets('renders no close button on a touch platform, even with '
      'onClose', (tester) async {
    await pumpAntgrid(
      tester,
      AbToast(icon: AbIcons.check, title: 'x', onClose: () {}),
    );
    expect(find.byTooltip('Dismiss'), findsNothing);
  }, variant: _touch);

  testWidgets('overlay: close button dismisses the toast immediately', (
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

    showAbToast(ctx, 'Path copied');
    await tester.pump();
    expect(find.text('Path copied'), findsOneWidget);

    // Well before the 4s default duration — proves the close button, not
    // the timer, is what took it down.
    await hoverRow(tester, find.byType(AbToast));
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Path copied'), findsNothing);
  }, variant: _desktop);

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
  }, variant: _desktop);

  testWidgets('overlay: keyboard focus reveals the close button', (
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

    // Programmatic, not Tab: the toast host sits beside the Navigator, outside
    // every route's focus scope, so route traversal never reaches it.
    final inner = find.descendant(
      of: find.byTooltip('Dismiss'),
      matching: find.byType(AbTapTarget),
    );
    Focus.of(tester.element(inner)).requestFocus();
    await tester.pump();
    await tester.pump();
    await tester.pump(AbTokens.motionSnap);
    expect(closeOpacity(), 1);
  }, variant: _desktop);

  testWidgets('overlay: dismisses on its own action tap', (tester) async {
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
  }, variant: _desktop);

  testWidgets('overlay: tapping a tappable card opens it and dismisses it', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    var opened = 0;

    showAbToastOverlay(
      ctx,
      toast: AbToast(
        icon: AbIcons.bell,
        title: 'Handler needs you',
        description: 'Ship it?',
        onTap: () => opened++,
      ),
      duration: const Duration(seconds: 8),
    );
    await tester.pump();

    await tester.tap(find.text('Ship it?'));
    await tester.pump();

    expect(opened, 1);
    expect(find.text('Handler needs you'), findsNothing);
  }, variant: TargetPlatformVariant.all());

  testWidgets('overlay: the close button on a tappable card does not open it', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    var opened = false;

    showAbToastOverlay(
      ctx,
      toast: AbToast(
        icon: AbIcons.bell,
        title: 'Handler needs you',
        onTap: () => opened = true,
      ),
    );
    await tester.pump();
    await hoverRow(tester, find.byType(AbToast));
    await tester.pump(AbTokens.motionSnap);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();

    expect(opened, isFalse);
    expect(find.text('Handler needs you'), findsNothing);
  }, variant: _desktop);

  testWidgets('touch: a fling dismisses the toast well before its timer', (
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

    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();
    expect(find.text('Copied to clipboard'), findsOneWidget);

    await tester.fling(find.byType(AbToast), const Offset(-300, 0), 1000);
    // The exit animation runs on a short delayed Future, not a pump-driven
    // animation — advance real time past it rather than pumpAndSettle.
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Copied to clipboard'), findsNothing);
  }, variant: _touch);

  testWidgets('touch: a short drag that falls short springs back, not '
      'dismissed', (tester) async {
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
  }, variant: _touch);

  testWidgets('desktop: the toast sits bottom-right, clear of the title bar', (
    tester,
  ) async {
    _sizeView(tester, const Size(1280, 800));
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();

    final rect = tester.getRect(find.byType(AbToast));
    expect(rect.right, 1280 - AbTokens.space16);
    expect(rect.bottom, 800 - AbTokens.space16);
    // The 40px title bar holds the caption buttons at the top-right.
    expect(rect.top, greaterThan(700));
  }, variant: _desktop);

  testWidgets('phone: the toast is centred above the inset and keyboard', (
    tester,
  ) async {
    _sizeView(tester, const Size(400, 800));
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    tester.view.padding = const FakeViewPadding(bottom: 34);
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();

    var rect = tester.getRect(find.byType(AbToast));
    expect(rect.center.dx, 200);
    expect(rect.bottom, 800 - 34 - AbTokens.space16);

    // A keyboard covers the system inset: the platform reports the padding
    // as consumed while viewPadding keeps the raw value.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = FakeViewPadding.zero;
    await tester.pump();

    rect = tester.getRect(find.byType(AbToast));
    expect(rect.center.dx, 200);
    expect(rect.bottom, 800 - 300 - AbTokens.space16);
  }, variant: _touch);

  testWidgets('the newest toast is nearest the bottom edge', (tester) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'first');
    showAbToast(ctx, 'second');
    await tester.pump();

    expect(
      tester.getBottomLeft(find.text('second')).dy,
      greaterThan(tester.getBottomLeft(find.text('first')).dy),
    );
  });

  testWidgets('dedupe: identical toasts share one card and restart its timer', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    for (var i = 0; i < 5; i++) {
      showAbToast(ctx, 'Copied to clipboard');
    }
    await tester.pump();
    expect(find.byType(AbToast), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();
    expect(find.byType(AbToast), findsOneWidget);

    // Past the first call's 4s, inside the last call's window.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Copied to clipboard'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('dedupe: a repeat landing as the old timer fires keeps the card', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3999));

    // pump elapses time (firing the old card's timer) before it builds the
    // repeat's card, so the old timer lands between the two.
    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.text('Copied to clipboard'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('touch: a repeat during a swipe-out shows a fresh card', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();
    await tester.fling(find.byType(AbToast), const Offset(-300, 0), 1000);
    await tester.pump(const Duration(milliseconds: 50));

    // Inside the swipe's exit delay: merging into the leaving card would
    // lose this one with it.
    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Copied to clipboard'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  }, variant: _touch);

  testWidgets('dedupe: a repeat moves the card to the newest position', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'a');
    showAbToast(ctx, 'b');
    showAbToast(ctx, 'a');
    await tester.pump();

    expect(find.byType(AbToast), findsNWidgets(2));
    expect(
      tester.getBottomLeft(find.text('a')).dy,
      greaterThan(tester.getBottomLeft(find.text('b')).dy),
    );
  });

  testWidgets('dedupe: repeats do not count against the burst cap', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    // A run of repeats at the tail would evict the originals if each one took
    // a slot, so every distinct title surviving proves the repeats merged.
    for (final title in ['a', 'b', 'c', 'd', 'a', 'a', 'a', 'a']) {
      showAbToast(ctx, title);
    }
    await tester.pump();

    expect(find.byType(AbToast), findsNWidgets(4));
    for (final title in ['a', 'b', 'c', 'd']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(
      tester.getTopLeft(find.text('a')).dy,
      greaterThan(tester.getTopLeft(find.text('d')).dy),
      reason: 'the merged toast moves to the newest slot, nearest the bottom',
    );
  });

  testWidgets('dedupe: a different description is not a repeat', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    showAbToastOverlay(
      ctx,
      toast: const AbToast(icon: AbIcons.info, title: 'Saved', description: 'a'),
    );
    showAbToastOverlay(
      ctx,
      toast: const AbToast(icon: AbIcons.info, title: 'Saved', description: 'b'),
    );
    await tester.pump();

    expect(find.byType(AbToast), findsNWidgets(2));
  });

  testWidgets('dedupe: toasts with an action are never merged', (tester) async {
    final ctx = await _pumpHost(tester);
    var firstActed = false;
    var secondActed = false;

    showAbToastOverlay(
      ctx,
      toast: AbToast(
        icon: AbIcons.info,
        title: 'Deleted',
        actionLabel: 'Undo',
        onAction: () => firstActed = true,
      ),
    );
    showAbToastOverlay(
      ctx,
      toast: AbToast(
        icon: AbIcons.info,
        title: 'Deleted',
        actionLabel: 'Undo',
        onAction: () => secondActed = true,
      ),
    );
    // A plain toast with the same title is not a repeat of an actionable one.
    showAbToast(ctx, 'Deleted');
    await tester.pump();

    expect(find.byType(AbToast), findsNWidgets(3));

    await tester.tap(find.text('Undo').first);
    await tester.pump();
    expect(firstActed, isTrue);
    expect(secondActed, isFalse);
  });

  testWidgets('dedupe: a repeat while hovered leaves the timer paused', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'Path copied');
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(AbToast)),
    );
    await tester.pump(const Duration(seconds: 10));

    showAbToast(ctx, 'Path copied');
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(AbToast), findsOneWidget);

    await gesture.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(AbToast), findsNothing);
  }, variant: _desktop);

  testWidgets('clearPrevious removes existing cards before adding', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'a');
    showAbToast(ctx, 'b');
    await tester.pump();
    expect(find.byType(AbToast), findsNWidgets(2));

    showAbToast(ctx, 'c', clearPrevious: true);
    await tester.pump();

    expect(find.byType(AbToast), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('host torn down before the timer fires: no error, no leaked '
      'timer', (tester) async {
    final ctx = await _pumpHost(tester);

    showAbToast(ctx, 'Copied to clipboard');
    await tester.pump();
    expect(find.byType(AbToast), findsOneWidget);

    // No long pump after teardown: a timer that dispose failed to cancel would
    // run to completion inside it. Left pending, it trips flutter_test's
    // end-of-test pending-timer check instead.
    await tester.pumpWidget(const SizedBox.shrink());

    expect(tester.takeException(), isNull);
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('showAbToast from the root NavigatorState context renders', (
    tester,
  ) async {
    await _pumpHost(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    showAbToast(navigator.context, 'Reported');
    await tester.pump();

    expect(find.text('Reported'), findsOneWidget);
  });

  group('AbToastHost', () {
    testWidgets('toasts render above an open dialog and take taps through its '
        'barrier', (tester) async {
      final ctx = await _pumpHost(tester);
      var acted = false;

      showAbToast(ctx, 'Before dialog');
      await tester.pump();
      unawaited(
        showDialog<void>(
          context: ctx,
          builder: (_) => const Center(child: Text('Dialog body')),
        ),
      );
      await tester.pumpAndSettle();

      showAbToastOverlay(
        ctx,
        toast: AbToast(
          icon: AbIcons.info,
          title: 'While dialog',
          actionLabel: 'Undo',
          onAction: () => acted = true,
        ),
        duration: const Duration(seconds: 8),
      );
      await tester.pump();

      expect(find.text('Dialog body'), findsOneWidget);
      expect(find.text('Before dialog').hitTestable(), findsOneWidget);
      expect(find.text('While dialog').hitTestable(), findsOneWidget);

      // The barrier is dismissible: had the tap reached it, the dialog would
      // have popped.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(acted, isTrue);
      expect(find.text('While dialog'), findsNothing);
      expect(find.text('Dialog body'), findsOneWidget);
    });

    testWidgets('a tap beside a toast reaches the page underneath', (
      tester,
    ) async {
      _sizeView(tester, const Size(1280, 800));
      late BuildContext ctx;
      var taps = 0;
      await pumpAntgrid(
        tester,
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: SizedBox.expand(
            child: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      showAbToast(ctx, 'Path copied');
      await tester.pump();
      final toast = tester.getRect(find.byType(AbToast));

      // Level with the card, and far from it.
      await tester.tapAt(Offset(AbTokens.space16, toast.center.dy));
      await tester.pump();
      await tester.tapAt(const Offset(AbTokens.space16, AbTokens.space16));
      await tester.pump();

      expect(taps, 2);
      expect(find.text('Path copied'), findsOneWidget);
    }, variant: _desktop);

    testWidgets('toasts from above and below the Navigator render in one '
        'stack', (tester) async {
      final contexts = await _pumpSplitContexts(tester);

      showAbToast(contexts.above, 'Copied to clipboard');
      showAbToast(contexts.route, 'Copied to clipboard');
      await tester.pump();
      expect(find.byType(AbToast), findsOneWidget);

      showAbToast(contexts.route, 'Saved');
      await tester.pump();
      expect(find.byType(AbToast), findsNWidgets(2));
      expect(
        tester.getTopLeft(find.text('Saved')).dy,
        greaterThan(tester.getBottomLeft(find.text('Copied to clipboard')).dy),
        reason: 'stacked in one column, newest nearest the bottom',
      );
    });
  });
}
