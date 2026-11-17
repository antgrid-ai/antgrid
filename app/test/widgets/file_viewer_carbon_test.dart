// The file viewers are Carbon: nothing under their scope may build an Ab
// widget, in any state, density or brightness. Each state below is one that
// could have kept a stray Ab helper.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/carbon_code_style.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:antgrid/widgets/file_viewer_router.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/toast_host.dart';

const _text = FileContent(
  path: 'docs/notes.txt',
  content: 'one\ntwo\nthree',
  size: 13,
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
);

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Brightness brightness = Brightness.light,
    CarbonDensity? density,
  }) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          themeAnimationDuration: Duration.zero,
          builder: abToastHostBuilder,
          home: Scaffold(
            body: AbCarbonScope(
              density: density,
              child: SizedBox.expand(child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  final states = <String, Widget Function()>{
    'loaded': () => const FileViewerRouter(fileContent: _text),
    'empty': () => const FileViewerRouter(),
    'loading': () => const FileViewerRouter(isLoading: true),
    'error': () => const FileViewerRouter(
      fileContent: FileContent(path: 'a.bin', size: 1, error: 'Unreadable'),
    ),
    'deleted': () => const FileViewerRouter(
      fileContent: FileContent(path: 'a.txt', size: 0, error: 'File not found'),
    ),
    'modified': () =>
        const FileViewerRouter(fileContent: _text, fileWasModified: true),
    'binary': () => const FileViewerRouter(
      fileContent: FileContent(
        path: 'app.exe',
        content: 'AAECAAM=',
        size: 5,
        encoding: 'base64',
        mimeType: 'application/octet-stream',
      ),
    ),
  };

  for (final brightness in Brightness.values) {
    for (final density in CarbonDensity.values) {
      for (final entry in states.entries) {
        testWidgets(
          'builds no Ab widget: ${entry.key}, ${brightness.name}, '
          '${density.name}',
          (tester) async {
            await pump(
              tester,
              entry.value(),
              brightness: brightness,
              density: density,
            );
            expect(abWidgetsInScope(tester), isEmpty);
          },
        );
      }
    }
  }

  testWidgets('builds no Ab widget with the find bar open', (tester) async {
    await pump(tester, const FileContentViewer(fileContent: _text));
    await tester.tap(_button('Search in file'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CarbonSearch), findsOneWidget);
    expect(
      tester.widget<CarbonButton>(_button('Search in file')).selected,
      isTrue,
    );
    expect(abWidgetsInScope(tester), isEmpty);

    await tester.tap(_button('Close search'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CarbonSearch), findsNothing);
    expect(
      tester.widget<CarbonButton>(_button('Search in file')).selected,
      isFalse,
    );
  });

  testWidgets('builds no Ab widget with the path menu open', (tester) async {
    await pump(tester, const FileContentViewer(fileContent: _text));
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(find.text('Copy relative path'), findsOneWidget);
    expect(find.text('Copy absolute path'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the editor renders at the diff viewer\'s code metrics', (
    tester,
  ) async {
    await pump(
      tester,
      const FileContentViewer(fileContent: _text),
      density: CarbonDensity.compact,
    );
    final expected = CarbonCodeStyle.from(
      CarbonThemeData.forBrightness(Brightness.light),
    ).text;
    final style = tester.widget<CodeEditor>(find.byType(CodeEditor)).style!;
    expect(style.fontSize, expected.fontSize);
    expect(style.fontFamily, expected.fontFamily);
    expect(style.fontHeight, expected.height);
  });
}
