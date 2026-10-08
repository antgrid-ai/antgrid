// app/test/widgets/viewer_header_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/widgets/viewer_header.dart';

import '../design/test_harness.dart';

void main() {
  testWidgets('renders the path as a breadcrumb and size, fires close', (
    tester,
  ) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildViewerHeader(
            path: 'assets/brand/logo.svg',
            size: 2048,
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    // One crumb per segment, the file last.
    expect(find.text('assets'), findsOneWidget);
    expect(find.text('brand'), findsOneWidget);
    expect(find.text('logo.svg'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    // Tap the close button by its widget type — AbIconButton avoids Material
    // ripples, so do NOT match on InkWell.
    await tester.tap(find.byType(AbIconButton));
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('clicking the breadcrumb offers relative and absolute copies', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpAntgrid(
      tester,
      const SizedBox(
        width: 400,
        child: ViewerPathBreadcrumb(path: 'docs/protocol/peer-session.md'),
      ),
    );

    await tester.tap(find.text('protocol'));
    await tester.pumpAndSettle();

    // Clicking opens the menu; nothing is copied until a row is picked.
    expect(copied, isEmpty);
    expect(find.text('Copy relative path'), findsOneWidget);
    expect(find.text('Copy absolute path'), findsOneWidget);

    await tester.tap(find.text('Copy relative path'));
    await tester.pumpAndSettle();

    expect(copied, ['docs/protocol/peer-session.md']);
    expect(find.text('Path copied'), findsOneWidget);
    // Let the toast run out.
    await tester.pump(const Duration(seconds: 5));
  });

  group('joinCheckoutPath', () {
    test('joins in the root\'s own separator style', () {
      expect(
        joinCheckoutPath('/home/me/repo', 'docs/a.md'),
        '/home/me/repo/docs/a.md',
      );
      expect(
        joinCheckoutPath(r'C:\src\repo\', 'docs/a.md'),
        r'C:\src\repo\docs\a.md',
      );
    });

    test('recognises paths that are already absolute', () {
      expect(isAbsoluteViewerPath('/tmp/out.png'), isTrue);
      expect(isAbsoluteViewerPath(r'C:\tmp\out.png'), isTrue);
      expect(isAbsoluteViewerPath(r'\\host\share\out.png'), isTrue);
      expect(isAbsoluteViewerPath('docs/a.md'), isFalse);
    });
  });

  // A path wider than the header keeps its END in view: the file name is
  // the part that must never be the one cut off.
  testWidgets('a long path keeps the file name on screen', (tester) async {
    await pumpAntgrid(
      tester,
      const SizedBox(
        // Room for the name in the test font (square 14px glyphs), not the
        // folders before it.
        width: 260,
        child: ViewerPathBreadcrumb(
          path: 'packages/antgrid_relay_client/lib/src/peer/session.dart',
        ),
      ),
    );
    final box = tester.getRect(find.byType(ViewerPathBreadcrumb));
    final name = tester.getRect(find.text('session.dart'));
    expect(name.right, lessThanOrEqualTo(box.right + 0.5));
    expect(name.left, greaterThanOrEqualTo(box.left));
  });
}
