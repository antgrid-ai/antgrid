import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _il = Key('il');

Widget _il0(
  CarbonInlineLoadingStatus status, {
  String? description = 'Saving',
  VoidCallback? onRetry,
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(
    width: 300,
    child: CarbonInlineLoading(
      key: _il,
      status: status,
      description: description,
      onRetry: onRetry,
    ),
  ),
);

/// Grows small sizes more than large ones, as Android's nonlinear font
/// scaling does.
class _Nonlinear extends TextScaler {
  const _Nonlinear();

  @override
  double scale(double fontSize) => fontSize * (fontSize < 20 ? 2.0 : 1.2);

  @override
  double get textScaleFactor => 2;

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) => this;

  @override
  bool operator ==(Object other) => other is _Nonlinear;

  @override
  int get hashCode => 1;
}


SemanticsNode _live(WidgetTester tester) => tester.getSemantics(
  find.descendant(
    of: find.byKey(_il),
    matching: find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.liveRegion != null,
    ),
  ),
);

void main() {
  testWidgets('a status change alters the live region label', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.active));
    final active = _live(tester).label;
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.finished));
    final finished = _live(tester).label;
    expect(finished, isNot(active));
    expect(finished, contains('Success'));
    handle.dispose();
  });

  testWidgets('a description-less status still announces its word', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    for (final entry in {
      CarbonInlineLoadingStatus.active: 'Loading',
      CarbonInlineLoadingStatus.finished: 'Success',
      CarbonInlineLoadingStatus.error: 'Error',
    }.entries) {
      await pumpCarbon(tester, _il0(entry.key, description: null));
      expect(_live(tester).label, entry.value);
    }
    handle.dispose();
  });

  testWidgets('focus stays inside when the retry button goes away', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _il0(CarbonInlineLoadingStatus.error, onRetry: () {}),
    );
    Focus.of(tester.element(find.text('Retry'))).requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNot(FocusManager.instance.rootScope));
    await pumpCarbon(tester, _il0(CarbonInlineLoadingStatus.active));
    expect(find.text('Retry'), findsNothing);
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull);
    expect(primary, isNot(FocusManager.instance.rootScope));
    final context = primary!.context;
    expect(context, isNotNull);
    var inside = false;
    context!.visitAncestorElements((e) {
      if (e.widget.key == _il) inside = true;
      return !inside;
    });
    expect(inside, isTrue);
  });

  testWidgets('indicator centers on the first line under a nonlinear scaler', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      MediaQuery(
        data: const MediaQueryData(textScaler: _Nonlinear()),
        child: _il0(CarbonInlineLoadingStatus.finished, description: 'Saved'),
      ),
    );
    final icon = tester.getRect(find.byType(CarbonIcon).first);
    final paragraph = tester.renderObject<RenderParagraph>(find.text('Saved'));
    final line = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 5),
        )
        .first;
    final lineCenter =
        paragraph.localToGlobal(Offset.zero).dy + (line.top + line.bottom) / 2;
    expect((icon.center.dy - lineCenter).abs(), lessThan(0.5));
  });
}
