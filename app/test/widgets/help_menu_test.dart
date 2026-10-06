import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/providers/app_version.dart';
import 'package:antgrid/widgets/help_menu.dart';
import 'package:antgrid/widgets/settings/legal_notices_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpHelp(
  WidgetTester tester, {
  Future<String> Function()? version,
  void Function(String)? opened,
  void Function(Rect?)? shared,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appVersionLabelProvider.overrideWith(
          (_) => version?.call() ?? Future.value('1.2.3 (456)'),
        ),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (anchor) => GestureDetector(
                  onTap: () {
                    final box = anchor.findRenderObject()! as RenderBox;
                    final rect = box.localToGlobal(Offset.zero) & box.size;
                    showAbMenu<void>(
                      context: context,
                      anchorRect: rect,
                      entries: [
                        helpMenu(
                          context: context,
                          ref: ref,
                          shareOrigin: rect,
                          openUrl: (ctx, url) async {
                            expect(Navigator.of(ctx).canPop(), isFalse);
                            opened?.call(url);
                          },
                          openChat: (ctx, _) async {
                            expect(Navigator.of(ctx).canPop(), isFalse);
                            opened?.call('chat');
                          },
                          openLogs: (ctx, origin) async {
                            expect(Navigator.of(ctx).canPop(), isFalse);
                            shared?.call(origin);
                          },
                        ),
                      ],
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _openHelp(tester);
}

Future<void> _openHelp(WidgetTester tester) async {
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Help'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'help actions dispatch the existing destinations after dismissal',
    (tester) async {
      final opened = <String>[];
      await _pumpHelp(tester, opened: opened.add);
      final destinations = {
        'Getting started': 'https://antgrid.ai/get-started',
        'Chat with support': 'chat',
        'Support centre': 'https://antgrid.ai/support',
        'Source code': 'https://github.com/antgrid-ai/antgrid',
      };
      for (final entry in destinations.entries) {
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(opened.last, entry.value);
        expect(find.byType(AbMenu), findsNothing);
        await _openHelp(tester);
      }
    },
  );

  testWidgets('version resolves while Help remains open', (tester) async {
    final version = Completer<String>();
    await _pumpHelp(tester, version: () => version.future);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('1.2.3 (456)'), findsNothing);
    version.complete('1.2.3 (456)');
    await tester.pumpAndSettle();
    expect(find.text('1.2.3 (456)'), findsOneWidget);
  });

  testWidgets('bundled legal notices open after dismissing Help', (
    tester,
  ) async {
    await _pumpHelp(tester);
    await tester.tap(find.text('Licences & notices'));
    await tester.pumpAndSettle();
    expect(find.byType(AbMenu), findsNothing);
    expect(find.byType(LegalNoticesSheet), findsOneWidget);
    expect(
      find.textContaining('Mozilla Public License Version 2.0'),
      findsOneWidget,
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('mobile shares logs with the surviving account-menu anchor', (
      tester,
    ) async {
      Rect? origin;
      await _pumpHelp(tester, shared: (value) => origin = value);
      expect(find.text('Share logs'), findsOneWidget);
      expect(find.text('Open log folder'), findsNothing);
      await tester.tap(find.text('Share logs'));
      await tester.pumpAndSettle();
      expect(origin, isNotNull);
      expect(origin!.width, greaterThan(0));
      expect(find.byType(AbMenu), findsNothing);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('desktop exposes Open log folder', (tester) async {
    await _pumpHelp(tester);
    expect(find.text('Open log folder'), findsOneWidget);
    expect(find.text('Share logs'), findsNothing);
  }, variant: TargetPlatformVariant.desktop());
}
