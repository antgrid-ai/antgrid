import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/viewer_support.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('viewerBasename', () {
    test('takes the last segment of a checkout path', () {
      expect(viewerBasename('lib/widgets/a.dart'), 'a.dart');
    });

    // A backslash is a legal filename character on Linux and macOS, so in a
    // checkout path it is part of the name, not a separator.
    test('keeps a backslash inside a POSIX file name', () {
      expect(viewerBasename(r'docs/notes\v2.txt'), r'notes\v2.txt');
    });

    test('splits a Windows absolute path on backslashes', () {
      expect(viewerBasename(r'C:\Users\me\shot.png'), 'shot.png');
      expect(viewerBasename(r'\\server\share\shot.png'), 'shot.png');
    });
  });

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AbCarbonScope(child: child)),
    ),
  );

  testWidgets('the modified banner is a warning with a Refresh action', (
    tester,
  ) async {
    var refreshed = 0;
    await pump(tester, ViewerModifiedBanner(onRefresh: () => refreshed++));
    expect(find.text('File changed externally'), findsOneWidget);
    final banner = tester.widget<CarbonNotification>(
      find.byType(CarbonNotification),
    );
    expect(banner.kind, CarbonNotificationKind.warning);
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(refreshed, 1);
  });

  testWidgets('the deleted state offers Close', (tester) async {
    var closed = false;
    await pump(tester, ViewerDeletedState(onClose: () => closed = true));
    expect(find.text('This file was deleted'), findsOneWidget);
    await tester.tap(find.text('Close'));
    expect(closed, isTrue);
  });

  testWidgets('the error notice shows the message inline as an error', (
    tester,
  ) async {
    await pump(tester, const ViewerErrorNotice(message: 'Disk on fire'));
    expect(find.text('Disk on fire'), findsOneWidget);
    expect(
      tester.widget<CarbonNotification>(find.byType(CarbonNotification)).kind,
      CarbonNotificationKind.error,
    );
  });

  testWidgets('an icon-only tool is named and latches when selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      const ViewerIconButton(
        icon: CarbonIcons.search,
        label: 'Search in file',
        selected: true,
      ),
    );
    expect(find.bySemanticsLabel('Search in file'), findsOneWidget);
    final button = tester.widget<CarbonButton>(find.byType(CarbonButton));
    expect(button.selected, isTrue);
    handle.dispose();
  });
}
