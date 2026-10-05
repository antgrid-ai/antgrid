import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/util/log_sharing.dart';
import 'package:antgrid/widgets/log_files_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/toast_host.dart';

Future<void> _pump(WidgetTester tester, LogFilesButton button) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        builder: abToastHostBuilder,
        home: Scaffold(body: Center(child: button)),
      ),
    );

void main() {
  final phones = [
    TargetPlatformVariant.only(TargetPlatform.android),
    TargetPlatformVariant.only(TargetPlatform.iOS),
  ];

  for (final variant in phones) {
    testWidgets('phones label the action share logs', (tester) async {
      await _pump(tester, const LogFilesButton());
      expect(find.text('share logs'), findsOneWidget);
      expect(find.text('open log folder'), findsNothing);
    }, variant: variant);

    testWidgets('uppercase phones label', (tester) async {
      await _pump(tester, const LogFilesButton(uppercase: true));
      expect(find.text('SHARE LOGS'), findsOneWidget);
    }, variant: variant);

    testWidgets('mobile tap shares with a real anchor rect', (tester) async {
      Rect? captured;
      var folderOpened = false;
      await _pump(
        tester,
        LogFilesButton(
          share: (origin) async {
            captured = origin;
            return LogShareOutcome.presented;
          },
          openFolder: () async {
            folderOpened = true;
            return true;
          },
        ),
      );
      await tester.tap(find.text('share logs'));
      await tester.pumpAndSettle();
      expect(captured, isNotNull);
      expect(captured!.width, greaterThan(0));
      expect(folderOpened, isFalse);
    }, variant: variant);

    testWidgets('mobile shows a toast when there is nothing to share', (
      tester,
    ) async {
      await _pump(
        tester,
        LogFilesButton(share: (_) async => LogShareOutcome.noLogFiles),
      );
      await tester.tap(find.text('share logs'));
      await tester.pump();
      await tester.pump();
      expect(find.text('No log file on this device yet.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }, variant: variant);
  }

  testWidgets('desktop labels the action open log folder', (tester) async {
    await _pump(tester, const LogFilesButton());
    expect(find.text('open log folder'), findsOneWidget);
    expect(find.text('share logs'), findsNothing);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('desktop tap opens the folder and toasts on failure', (
    tester,
  ) async {
    var opened = 0;
    var shared = 0;
    await _pump(
      tester,
      LogFilesButton(
        share: (_) async {
          shared++;
          return LogShareOutcome.presented;
        },
        openFolder: () async {
          opened++;
          return false;
        },
      ),
    );
    await tester.tap(find.text('open log folder'));
    await tester.pump();
    await tester.pump();
    expect(opened, 1);
    expect(shared, 0);
    expect(find.text('Could not open the log folder.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.desktop());
}
