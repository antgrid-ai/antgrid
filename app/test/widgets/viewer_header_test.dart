// app/test/widgets/viewer_header_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_download.dart';
import 'package:antgrid/widgets/viewer_header.dart';

import '../helpers/toast_host.dart';
import '../helpers/clipboard.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        builder: abToastHostBuilder,
        home: Scaffold(
          body: AbCarbonScope(child: Center(child: child)),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'renders the path as a breadcrumb, offers download, fires close',
    (tester) async {
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AbCarbonScope(
              child: buildViewerHeader(
                content: const FileContent(
                  path: 'assets/brand/logo.svg',
                  content: '<svg/>',
                  size: 2048,
                ),
                onClose: () => closed = true,
              ),
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
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel == 'Close file',
        ),
      );
      await tester.pump();
      expect(closed, isTrue);
    },
  );

  testWidgets('a file with nothing held offers no download', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AbCarbonScope(
            child: buildViewerHeader(
              content: const FileContent(
                path: 'big.bin',
                size: 9000000,
                error: 'File too large',
              ),
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

  // The bridge decodes text as UTF-8, so a Latin-1 file's 'é' (one byte, 0xE9)
  // arrives as U+FFFD and would re-encode to three bytes that were never there.
  test('download refuses text the bridge could not decode losslessly', () {
    expect(
      fileContentBytes(
        const FileContent(path: 'a.txt', content: 'h�', size: 2),
      ),
      isNull,
    );
  });

  test('download refuses equal-length lossy text from older bridges', () {
    expect(
      fileContentBytes(
        const FileContent(path: 'a.txt', content: '\uFFFD', size: 3),
      ),
      isNull,
    );
  });

  test('download distinguishes malformed bytes from a literal replacement', () {
    for (final valid in [false, true]) {
      expect(
        fileContentBytes(
          FileContent(
            path: 'a.txt',
            content: '\uFFFD',
            size: 3,
            utf8Valid: valid,
          ),
        ),
        valid ? [0xEF, 0xBF, 0xBD] : isNull,
      );
    }
  });

  testWidgets('clicking the breadcrumb offers relative and absolute copies', (
    tester,
  ) async {
    final copied = captureClipboard(tester);
    await _pump(
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
    await _pump(
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
    await _pump(
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

  testWidgets('an embedding host drops the path, download and close', (tester) async {
    await _pump(
      tester,
      ViewerChrome(
        child: buildViewerHeader(
          content: const FileContent(path: 'a/b.md', content: 'x', size: 1),
          onClose: () {},
        ),
      ),
    );
    expect(find.byType(ViewerPathBreadcrumb), findsNothing);
    expect(find.byKey(const Key('file-download')), findsNothing);
    expect(find.byType(CarbonButton), findsNothing);
  });

  testWidgets('Download and Close read as buttons by name', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      buildViewerHeader(
        content: const FileContent(path: 'a/b.md', content: 'x', size: 1),
        onClose: () {},
      ),
    );
    expect(find.bySemanticsLabel('Download'), findsOneWidget);
    expect(find.bySemanticsLabel('Close file'), findsOneWidget);
    handle.dispose();
  });
}
