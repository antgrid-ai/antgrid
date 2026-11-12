import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _spinner = Key('spinner');

Widget _host(Widget child) => Align(alignment: Alignment.topLeft, child: child);

void main() {
  group('CarbonSpinner ticking', () {
    testWidgets('animates and repaints only the arc layer', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSpinner(key: _spinner)));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byKey(_spinner),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
    });

    testWidgets('TickerMode disabled mutes it and re-enabling resumes', (
      tester,
    ) async {
      Widget tree(bool enabled) => _host(
        TickerMode(enabled: enabled, child: const CarbonSpinner()),
      );
      await pumpCarbon(tester, tree(false));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, 0);
      await pumpCarbon(tester, tree(true));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await pumpCarbon(tester, tree(false));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('reduced motion has no ticker and live toggle restores it', (
      tester,
    ) async {
      await pumpCarbon(tester, _host(const CarbonSpinner()), reduceMotion: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, 0);
      await pumpCarbon(tester, _host(const CarbonSpinner()));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await pumpCarbon(tester, _host(const CarbonSpinner()), reduceMotion: true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('inactive spinner does not tick', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSpinner(active: false)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, 0);
      await pumpCarbon(tester, _host(const CarbonSpinner()));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('unmounting stops all frames', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSpinner()));
      await pumpCarbon(tester, _host(const SizedBox()));
      expect(tester.binding.transientCallbackCount, 0);
      for (var i = 0; i < 3; i++) {
        await pumpCarbon(tester, _host(const CarbonSpinner()));
        await pumpCarbon(tester, _host(const SizedBox()));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('size, color and theme changes keep it mounted', (
      tester,
    ) async {
      await pumpCarbon(tester, _host(const CarbonSpinner(key: _spinner)));
      final state = tester.state(find.byKey(_spinner));
      await pumpCarbon(
        tester,
        _host(const CarbonSpinner(key: _spinner, size: 88)),
        theme: CarbonThemeData(scheme: CarbonThemeScheme.gray100),
      );
      expect(tester.state(find.byKey(_spinner)), same(state));
      expect(tester.getSize(find.byKey(_spinner)), const Size(88, 88));
    });
  });

  group('CarbonSpinner semantics', () {
    testWidgets('is decorative by default and labelled on request', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _host(const CarbonSpinner()));
      expect(find.bySemanticsLabel('Working'), findsNothing);
      await pumpCarbon(tester, _host(const CarbonSpinner(semanticLabel: 'Working')));
      expect(find.bySemanticsLabel('Working'), findsOneWidget);
      handle.dispose();
    });
  });

  group('CarbonLoading', () {
    testWidgets('sizes follow the Carbon scale', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonLoading(size: CarbonLoadingSize.small, key: _spinner)),
      );
      expect(tester.getSize(find.byKey(_spinner)), const Size(16, 16));
      await pumpCarbon(
        tester,
        _host(const CarbonLoading(key: _spinner)),
      );
      expect(tester.getSize(find.byKey(_spinner)).width, 88);
    });

    testWidgets('announces localized Loading through a live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _host(const CarbonLoading(key: _spinner)));
      expect(
        tester.getSemantics(find.byKey(_spinner)),
        matchesSemantics(label: 'Loading', isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('message is shown and announced once, not twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(const CarbonLoading(key: _spinner, message: 'Fetching files')),
      );
      expect(find.text('Fetching files'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(_spinner)),
        matchesSemantics(label: 'Fetching files', isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('semantic label overrides the message', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(
          const CarbonLoading(
            key: _spinner,
            message: 'Fetching',
            semanticLabel: 'Fetching the file list',
          ),
        ),
      );
      expect(find.bySemanticsLabel('Fetching the file list'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('survives 200% text, RTL and a density switch', (tester) async {
      final harness = await pumpCarbon(
        tester,
        _host(const CarbonLoading(message: 'A long loading message that wraps')),
        size: const Size(200, 600),
        textScale: 2,
        dir: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.takeException(), isNull);
    });
  });

  group('CarbonLoadingOverlay', () {
    testWidgets('covers only its own region and blocks it', (tester) async {
      var inside = 0;
      var outside = 0;
      Widget tree(bool loading) => Column(
        children: [
          SizedBox(
            width: 200,
            height: 100,
            child: CarbonLoadingOverlay(
              loading: loading,
              size: CarbonLoadingSize.small,
              child: CarbonButton(
                key: const Key('inside'),
                label: 'In',
                onPressed: () => inside++,
              ),
            ),
          ),
          CarbonButton(
            key: const Key('outside'),
            label: 'Out',
            onPressed: () => outside++,
          ),
        ],
      );
      await pumpCarbon(tester, tree(false));
      await tester.tap(find.byKey(const Key('inside')));
      expect(inside, 1);

      await pumpCarbon(tester, tree(true));
      await tester.tap(find.byKey(const Key('inside')), warnIfMissed: false);
      await tester.tap(find.byKey(const Key('outside')));
      expect(inside, 1);
      expect(outside, 1);
      expect(find.byType(CarbonLoading), findsOneWidget);

      await pumpCarbon(tester, tree(false));
      expect(find.byType(CarbonLoading), findsNothing);
      await tester.tap(find.byKey(const Key('inside')));
      expect(inside, 2);
    });

    testWidgets('removes covered controls from keyboard focus', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      Widget tree(bool loading) => SizedBox(
        width: 200,
        height: 100,
        child: CarbonLoadingOverlay(
          loading: loading,
          child: CarbonButton(label: 'In', focusNode: node, onPressed: () {}),
        ),
      );
      await pumpCarbon(tester, tree(false));
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      await pumpCarbon(tester, tree(true));
      expect(node.hasFocus, isFalse);
      expect(node.canRequestFocus, isFalse);
      await pumpCarbon(tester, tree(false));
      expect(node.canRequestFocus, isTrue);
    });
  });
}
