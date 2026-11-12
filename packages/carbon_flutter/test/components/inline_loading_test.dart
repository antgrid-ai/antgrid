import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _il = Key('il');

Widget _host(Widget child, {double width = 300}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Widget _il0(
  CarbonInlineLoadingStatus status, {
  String? description = 'Saving',
  VoidCallback? onRetry,
}) => _host(
  CarbonInlineLoading(
    key: _il,
    status: status,
    description: description,
    onRetry: onRetry,
  ),
);


SemanticsNode _live(WidgetTester tester) => tester.getSemantics(
  find.descendant(
    of: find.byKey(_il),
    matching: find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.liveRegion != null,
    ),
  ),
);

void main() {
  testWidgets('active shows a spinner that ticks', (tester) async {
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.active));
    expect(find.byType(CarbonSpinner), findsOneWidget);
    expect(find.text('Saving'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('finished and error show their icons, no spinner, no ticks', (
    tester,
  ) async {
    for (final s in [
      CarbonInlineLoadingStatus.finished,
      CarbonInlineLoadingStatus.error,
    ]) {
      await pumpCarbon(tester, _il0(s));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(CarbonSpinner), findsNothing);
      expect(find.byType(CarbonIcon), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    }
  });

  testWidgets('inactive shows no indicator and no ticks', (tester) async {
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.inactive));
    expect(find.byType(CarbonSpinner), findsNothing);
    expect(find.byType(CarbonIcon), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('description stays at the same x in every status', (
    tester,
  ) async {
    final xs = <double>{};
    for (final s in CarbonInlineLoadingStatus.values) {
      await pumpCarbon(tester, _il0(s));
      xs.add(tester.getTopLeft(find.text('Saving')).dx);
    }
    expect(xs.length, 1);
  });

  testWidgets('reduced motion and TickerMode stop the spinner ticking', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _il0(CarbonInlineLoadingStatus.active),
      reduceMotion: true,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 0);
    await pumpCarbon(
      tester,
      TickerMode(enabled: false, child: _il0(CarbonInlineLoadingStatus.active)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('status changes announce through a live region keyed to status', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.active));
    expect(
      _live(tester),
      matchesSemantics(label: 'Saving, Loading', isLiveRegion: true),
    );
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.finished));
    expect(
      _live(tester),
      matchesSemantics(label: 'Saving, Success', isLiveRegion: true),
    );
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.error));
    expect(
      _live(tester),
      matchesSemantics(label: 'Saving, Error', isLiveRegion: true),
    );
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.inactive));
    expect(
      _live(tester),
      matchesSemantics(label: 'Saving'),
    );
    handle.dispose();
  });

  testWidgets('frames do not rebuild the surrounding tree', (tester) async {
    var builds = 0;
    await pumpCarbon(
      tester,
      _host(
        Builder(
          builder: (context) {
            builds++;
            return const CarbonInlineLoading(
              status: CarbonInlineLoadingStatus.active,
              description: 'Saving',
            );
          },
        ),
      ),
    );
    final before = builds;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(builds, before);
  });

  group('retry', () {
    testWidgets('is shown only on error with a callback and is never automatic', (
      tester,
    ) async {
      var retries = 0;
      for (final s in [
        CarbonInlineLoadingStatus.active,
        CarbonInlineLoadingStatus.finished,
      ]) {
        await pumpCarbon(tester, _il0(s, onRetry: () => retries++));
        expect(find.text('Retry'), findsNothing);
      }
      await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.error));
      expect(find.text('Retry'), findsNothing);
      await pumpCarbon(
        tester,
        _il0(CarbonInlineLoadingStatus.error, onRetry: () => retries++),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(retries, 0);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });

    testWidgets('is a button with a semantic label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _il0(CarbonInlineLoadingStatus.error, onRetry: () {}),
      );
      expect(find.bySemanticsLabel('Retry'), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('long description wraps at 200% text in RTL without overflow', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _host(
        const CarbonInlineLoading(
          status: CarbonInlineLoadingStatus.error,
          description:
              'Could not save the project because the connection dropped',
        ),
        width: 160,
      ),
      textScale: 2,
      dir: TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
    await pumpCarbon(
      tester,
      _host(
        CarbonInlineLoading(
          status: CarbonInlineLoadingStatus.error,
          description: 'Could not save',
          onRetry: () {},
        ),
        width: 160,
      ),
      textScale: 2,
      dir: TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('density switch keeps the widget mounted', (tester) async {
    final harness = await pumpCarbon(
      tester,
      _il0(CarbonInlineLoadingStatus.active),
    );
    final state = tester.state(find.byType(CarbonSpinner));
    await harness.setDensity(tester, CarbonDensity.touch);
    expect(tester.state(find.byType(CarbonSpinner)), same(state));
  });
}
