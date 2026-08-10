import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/providers/app_version.dart';
import 'package:antgrid/widgets/settings/help_about_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('link rows open their URLs via the injected opener', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _wrap(
        HelpAboutSection(openUrl: (context, url) async => opened.add(url)),
        overrides: [
          appVersionLabelProvider.overrideWith((ref) async => '1.2.3 (456)'),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Getting started'));
    expect(opened, ['https://antgrid.ai/get-started']);

    await tester.tap(find.text('Support'));
    expect(opened, [
      'https://antgrid.ai/get-started',
      'https://antgrid.ai/support',
    ]);
  });

  testWidgets('version row renders the resolved version label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        HelpAboutSection(openUrl: (context, url) async {}),
        overrides: [
          appVersionLabelProvider.overrideWith((ref) async => '1.2.3 (456)'),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('1.2.3 (456)'), findsOneWidget);
  });
}
