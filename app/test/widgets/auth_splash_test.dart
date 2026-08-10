import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/widgets/auth_splash.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

// Mobile platform so the mobile branch renders — the desktop branch mounts
// WindowTitleBar, which is chrome, not the splash content under test.
Widget _wrap({bool disableAnimations = false}) {
  return MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: const AuthSplash(),
  );
}

void main() {
  testWidgets('renders wordmark and loading cursor after the fade', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_wrap());
    await tester.pump(AbTokens.motionSettle);

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(AbLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reduce motion renders statically without looping', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_wrap(disableAnimations: true));
    await tester.pump();

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(AbLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
