// app/test/widgets/viewer_header_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_download.dart';
import 'package:antgrid/widgets/viewer_header.dart';

import '../design/test_harness.dart';
import '../helpers/clipboard.dart';

void main() {
  testWidgets(
    'renders the path as a breadcrumb, offers download, fires close',
    (tester) async {
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: buildViewerHeader(
              content: const FileContent(
                path: 'assets/brand/logo.svg',
                content: '<svg/>',
                size: 2048,
              ),
              onClose: () => closed = true,
            ),
          ),
        ),
      );
      // One crumb per segment, the file last.
      expect(find.text('assets'), findsOneWidget);
      expect(find.text('brand'), findsOneWidget);
      expect(find.text('logo.svg'), findsOneWidget);
      expect(find.text('2.0 KB'), findsNothing);
      expect(find.byKey(const Key('file-download')), findsOneWidget);
      // Close is the last button. AbIconButton avoids Material ripples, so do
      // NOT match on InkWell.
      await tester.tap(find.byType(AbIconButton).last);
      await tester.pump();
      expect(closed, isTrue);
    },
  );

  testWidgets('a file with nothing held offers no download', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildViewerHeader(
            content: const FileContent(
              path: 'big.bin',
              size: 9000000,
              error: 'File too large',
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('file-download')), findsNothing);
  });

  test('download saves exactly the bytes the viewer holds', () {
    expect(
      fileContentBytes(
        const FileContent(path: 'a.txt', content: 'hé', size: 3),
      ),
      [0x68, 0xC3, 0xA9],
    );
    expect(
      fileContentBytes(
        const FileContent(
          path: 'a.png',
          content: 'AQID',
          size: 3,
          encoding: 'base64',
        ),
      ),
      [1, 2, 3],
    );
  });

  testWidgets('clicking the breadcrumb offers relative and absolute copies', (
    tester,
  ) async {
    final copied = captureClipboard(tester);
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

  testWidgets('an image outside the checkout offers only its absolute path', (
    tester,
  ) async {
    const path =
        r'C:\Users\me\Temp\claude\66dd53be-1f2a-4b3c-9d8e-0f1a2b3a8631\scratchpad\shot.png';
    final copied = captureClipboard(tester);
    await pumpAntgrid(
      tester,
      const SizedBox(width: 2000, child: ViewerPathBreadcrumb(path: path)),
    );

    // A long folder keeps its ends on screen; the file name is never cut.
    expect(find.text('66dd53be…a8631'), findsOneWidget);
    expect(find.text('shot.png'), findsOneWidget);

    await tester.tap(find.text('scratchpad'));
    await tester.pumpAndSettle();

    expect(find.text('Copy relative path'), findsNothing);
    await tester.tap(find.text('Copy absolute path'));
    await tester.pumpAndSettle();

    expect(copied, [path]);
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
