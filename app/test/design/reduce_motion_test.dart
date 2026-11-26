import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';

/// Minimal shell around [AbLoading]: the design system reads reduce-motion
/// exclusively via `MediaQuery.disableAnimationsOf`, so the harness only
/// needs a MediaQuery + themed Directionality — no MaterialApp, no Riverpod.
Widget _harness({required bool disableAnimations}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: buildAbTheme(kDefaultPalette),
        child: const AbLoading(),
      ),
    ),
  );
}

void main() {
  testWidgets('AbLoading pulses when animations are enabled', (tester) async {
    await tester.pumpWidget(_harness(disableAnimations: false));

    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('AbLoading holds still under disableAnimations', (tester) async {
    await tester.pumpWidget(_harness(disableAnimations: true));

    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a live reduce-motion flip stops and restarts the pulse', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(disableAnimations: false));
    expect(tester.hasRunningAnimations, isTrue);

    // Same widget tree, only the ambient MediaQuery changes — exercises the
    // didChangeDependencies re-sync rather than a fresh initState.
    await tester.pumpWidget(_harness(disableAnimations: true));
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(_harness(disableAnimations: false));
    expect(tester.hasRunningAnimations, isTrue);
  });
}
