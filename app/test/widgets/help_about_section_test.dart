import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/providers/app_version.dart';
import 'package:antgrid/widgets/settings/help_about_section.dart';
import 'package:antgrid/widgets/settings/legal_notices_sheet.dart';
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
        HelpAboutSection(
          openUrl: (context, url) async => opened.add(url),
          openChat: (context, ref) async => opened.add('chat'),
        ),
        overrides: [
          appVersionLabelProvider.overrideWith((ref) async => '1.2.3 (456)'),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Getting started'));
    expect(opened, ['https://antgrid.ai/get-started']);

    await tester.tap(find.text('Chat with support'));
    expect(opened, ['https://antgrid.ai/get-started', 'chat']);

    await tester.tap(find.text('Support centre'));
    expect(opened, [
      'https://antgrid.ai/get-started',
      'chat',
      'https://antgrid.ai/support',
    ]);

    await tester.tap(find.text('Source code'));
    expect(opened.last, 'https://github.com/antgrid-ai/antgrid');
  });

  testWidgets('version row renders the resolved version label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        HelpAboutSection(
          openUrl: (context, url) async {},
          openChat: (context, ref) async {},
        ),
        overrides: [
          appVersionLabelProvider.overrideWith((ref) async => '1.2.3 (456)'),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('1.2.3 (456)'), findsOneWidget);
  });

  testWidgets('bundled notices are readable without opening a URL', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        HelpAboutSection(
          openUrl: (context, url) async {},
          openChat: (context, ref) async {},
        ),
        overrides: [appVersionLabelProvider.overrideWith((ref) async => 'dev')],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Licences & notices'));
    await tester.pumpAndSettle();

    expect(find.byType(LegalNoticesSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LegalNoticesSheet),
        matching: find.text('Licences & notices'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Mozilla Public License Version 2.0'),
      findsOneWidget,
    );
  });
}
