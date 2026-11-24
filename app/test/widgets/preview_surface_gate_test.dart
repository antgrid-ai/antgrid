import 'package:antgrid/widgets/display_visibility.dart';
import 'package:antgrid/widgets/preview_surface_gate.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the WebView plugins' surface box: they stop rendering only
/// when this ancestor walk says the box is not painted, and start again when
/// the box's own `paint` runs.
class _SurfaceProbe extends SingleChildRenderObjectWidget {
  const _SurfaceProbe();

  @override
  _RenderSurfaceProbe createRenderObject(BuildContext context) =>
      _RenderSurfaceProbe();
}

class _RenderSurfaceProbe extends RenderProxyBox {
  int paints = 0;

  bool get isEffectivelyPainted {
    RenderObject child = this;
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      if (!ancestor.paintsChild(child)) return false;
      child = ancestor;
      ancestor = ancestor.parent;
    }
    return true;
  }

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    paints++;
  }
}

Widget _host({required bool panelVisible, required bool isActiveTab}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: DisplayVisibilityScope(
      visible: panelVisible,
      child: PreviewSurfaceGate(
        isActiveTab: isActiveTab,
        child: const _SurfaceProbe(),
      ),
    ),
  );
}

_RenderSurfaceProbe _probe(WidgetTester tester) =>
    tester.renderObject<_RenderSurfaceProbe>(
      find.byType(_SurfaceProbe, skipOffstage: false),
    );

final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  testWidgets('an IndexedStack alone still reports a hidden child as painted', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IndexedStack(
          index: 0,
          children: [SizedBox.expand(), _SurfaceProbe()],
        ),
      ),
    );
    final probe = _probe(tester);
    expect(probe.paints, 0);
    expect(probe.isEffectivelyPainted, isTrue);
  });

  testWidgets('a preview behind another workspace tab is not painted', (
    tester,
  ) async {
    await tester.pumpWidget(_host(panelVisible: false, isActiveTab: true));
    expect(_probe(tester).isEffectivelyPainted, isFalse);
  }, variant: _desktop);

  testWidgets('a background preview tab is not painted', (tester) async {
    await tester.pumpWidget(_host(panelVisible: true, isActiveTab: false));
    expect(_probe(tester).isEffectivelyPainted, isFalse);
  }, variant: _desktop);

  testWidgets('the active preview on screen paints again after being hidden', (
    tester,
  ) async {
    await tester.pumpWidget(_host(panelVisible: false, isActiveTab: true));
    final probe = _probe(tester);
    final paintsWhileHidden = probe.paints;

    await tester.pumpWidget(_host(panelVisible: true, isActiveTab: true));

    expect(probe.isEffectivelyPainted, isTrue);
    expect(probe.paints, greaterThan(paintsWhileHidden));
  }, variant: _desktop);

  testWidgets('a phone ignores panel visibility, which flips mid-swipe', (
    tester,
  ) async {
    await tester.pumpWidget(_host(panelVisible: false, isActiveTab: true));
    expect(_probe(tester).isEffectivelyPainted, isTrue);

    await tester.pumpWidget(_host(panelVisible: false, isActiveTab: false));
    expect(_probe(tester).isEffectivelyPainted, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
