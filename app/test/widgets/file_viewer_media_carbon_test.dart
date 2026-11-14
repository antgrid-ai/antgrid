// The markdown, SVG, image and PDF viewers are Carbon: nothing under their
// scope may build an Ab widget, in any state, density or brightness.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/image_viewer.dart';
import 'package:antgrid/widgets/markdown_outline.dart';
import 'package:antgrid/widgets/markdown_preview.dart';
import 'package:antgrid/widgets/pdf_viewer.dart';
import 'package:antgrid/widgets/svg_preview.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/toast_host.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
    '<rect width="10" height="10" fill="red"/></svg>';

const _markdown = FileContent(
  path: 'docs/architecture.md',
  content:
      '# Architecture\n\n## Bridge\n\n## Relay\n\n'
      'Text with `code`, a [link](https://example.com) and an '
      '![shot](shot.png).\n\n- [x] done\n- [ ] todo\n\n'
      '```bash\nnpm run setup\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n',
  size: 200,
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
);

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Brightness brightness = Brightness.light,
    CarbonDensity? density,
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
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
    await tester.pump(const Duration(milliseconds: 100));
  }

  final states = <String, Widget Function()>{
    'markdown with outline': () => const MarkdownPreview(content: _markdown),
    'markdown modified': () =>
        const MarkdownPreview(content: _markdown, fileWasModified: true),
    'svg': () => const SvgPreview(
      content: FileContent(path: 'a.svg', content: _svg, size: 80),
    ),
    'svg empty': () => const SvgPreview(
      content: FileContent(path: 'a.svg', content: '', size: 0),
    ),
    'image': () => const ImageViewer(
      content: FileContent(
        path: 'a.png',
        content: _png,
        size: 70,
        encoding: 'base64',
        mimeType: 'image/png',
      ),
    ),
    'image error': () => const ImageViewer(
      content: FileContent(
        path: 'a.png',
        content: '!!!not-base64!!!',
        size: 5,
        encoding: 'base64',
      ),
    ),
    'pdf error': () => const FilePdfViewer(
      content: FileContent(
        path: 'a.pdf',
        content: '!!!not-base64!!!',
        size: 5,
        encoding: 'base64',
        mimeType: 'application/pdf',
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

  testWidgets('the outline toggle latches and the rail follows it', (
    tester,
  ) async {
    await pump(tester, const MarkdownPreview(content: _markdown));
    expect(find.byType(MarkdownOutline), findsOneWidget);
    expect(find.byType(CarbonTreeView), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);

    await tester.tap(_button('Hide outline'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MarkdownOutline), findsNothing);
    expect(_button('Show outline'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the narrow outline overlay builds no Ab widget', (tester) async {
    await pump(
      tester,
      const MarkdownPreview(content: _markdown),
      size: const Size(600, 800),
    );
    await tester.tap(_button('Show outline'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MarkdownOutline), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the source toggle is a named Carbon button', (tester) async {
    await pump(
      tester,
      const SvgPreview(
        content: FileContent(path: 'a.svg', content: _svg, size: 80),
      ),
    );
    expect(_button('Show source'), findsOneWidget);
  });
}
