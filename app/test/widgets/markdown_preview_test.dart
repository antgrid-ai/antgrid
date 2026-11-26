import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/markdown_outline.dart';
import 'package:antgrid/widgets/markdown_document_config.dart' show joinSoftBreaks;
import 'package:antgrid/widgets/markdown_preview.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:antgrid/widgets/viewer_support.dart';

void main() {
  setUpAll(() {
    // markdown_widget uses VisibilityDetector which has a debounce timer.
    // Setting updateInterval to zero makes callbacks fire synchronously in tests,
    // preventing the "pending timer" assertion failure on teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('renders heading text from markdown source', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              content: const FileContent(
                path: 'readme.md',
                content: '# Hello Antgrid',
                size: 15,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hello Antgrid'), findsOneWidget);
  });

  testWidgets('opens in source view when a search line is set', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              content: const FileContent(
                path: 'readme.md',
                content: '# Hello\n\nworld',
                size: 14,
              ),
              searchLine: 3,
              searchQuery: 'world',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Search-to-line can't target a rendered preview, so it must land on source.
    expect(find.byType(FileContentViewer), findsOneWidget);
  });

  testWidgets(
    'switches to source when a search hit lands on an already-open file',
    (tester) async {
      Widget host(int? line) => ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              key: const ValueKey('readme.md'),
              content: const FileContent(
                path: 'readme.md',
                content: '# Hello\n\nworld',
                size: 14,
              ),
              searchLine: line,
              searchQuery: line == null ? null : 'world',
            ),
          ),
        ),
      );

      // Opened normally (no search) → rendered preview, not source.
      await tester.pumpWidget(host(null));
      await tester.pumpAndSettle();
      expect(find.byType(FileContentViewer), findsNothing);

      // A search hit arrives for the same already-open path → must jump to source.
      await tester.pumpWidget(host(3));
      await tester.pumpAndSettle();
      expect(find.byType(FileContentViewer), findsOneWidget);
    },
  );

  testWidgets('shows the modified banner in rendered preview mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              content: const FileContent(
                path: 'readme.md',
                content: '# Hello',
                size: 7,
              ),
              fileWasModified: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ViewerModifiedBanner), findsOneWidget);
  });

  Widget host(FileContent content, {ValueChanged<String>? onOpenFile}) =>
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(content: content, onOpenFile: onOpenFile),
          ),
        ),
      );

  void widen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  const outlined = FileContent(
    path: 'docs/architecture.md',
    content: '# Architecture\n\n## Bridge\n\n## Relay\n\ntext\n',
    size: 48,
  );

  testWidgets('shows the heading outline beside a wide document', (
    tester,
  ) async {
    widen(tester);
    await tester.pumpWidget(host(outlined));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsOneWidget);
    expect(find.byTooltip('Hide outline'), findsOneWidget);
  });

  testWidgets('hides the outline when the reader closes it', (tester) async {
    widen(tester);
    await tester.pumpWidget(host(outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Hide outline'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsNothing);
    expect(find.byTooltip('Show outline'), findsOneWidget);
  });

  testWidgets('offers no outline for a document with too few headings', (
    tester,
  ) async {
    widen(tester);
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: '# Only one heading\n\nbody\n',
          size: 26,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsNothing);
    // 'Hide outline' is what the toggle would say here: the pane is wide and
    // the reader has not touched it, so asserting on 'Show outline' would pass
    // for any document at all.
    expect(find.byTooltip('Hide outline'), findsNothing);
  });

  testWidgets('keeps the outline off the document on a narrow pane', (
    tester,
  ) async {
    // Default 800x600 surface — below kMediumBreakpoint.
    await tester.pumpWidget(host(outlined));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsNothing);

    await tester.tap(find.byTooltip('Show outline'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsOneWidget);
  });

  testWidgets('scrolls from the gutter beside the capped measure', (
    tester,
  ) async {
    // The measure is capped by padding, so the ListView still spans the pane:
    // boxing it at AbTokens.documentMaxWidth instead leaves every wheel turn
    // and drag right of the text landing on no Scrollable at all.
    widen(tester);
    await tester.pumpWidget(
      host(
        FileContent(
          path: 'docs/long.md',
          content: '# Long\n\n${'paragraph text\n\n' * 120}',
          size: 2048,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final document = find
        .descendant(
          of: find.byType(MarkdownWidget),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(document).position;
    expect(position.pixels, 0);

    // x=1200 is past the 720pt measure and left of the outline rail.
    await tester.dragFrom(const Offset(1200, 400), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('an outline jump does not latch the rail shut', (tester) async {
    // Default 800x600 surface — the outline opens over the document.
    await tester.pumpWidget(host(outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show outline'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(MarkdownOutline),
        matching: find.text('Bridge'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsNothing);

    // Dismissing after a jump returns the toggle to following the pane width,
    // so a pane that later has room for the rail shows it.
    widen(tester);
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownOutline), findsOneWidget);
  });

  testWidgets('an ordered index is not part of the copied text', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: '1. first\n2. second\n',
          size: 20,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The package excludes its own index marker from selection; a custom
    // marker that forgets to glues `1.` onto every copied item.
    expect(
      find.ancestor(
        of: find.text('1.'),
        matching: find.byType(SelectionContainer),
      ),
      findsWidgets,
    );
  });

  testWidgets('inline code keeps the mono face inside a sans paragraph', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: 'run `flutter test` now\n',
          size: 22,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final families = <String, String?>{};
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      text.text.visitChildren((span) {
        if (span is TextSpan && (span.text ?? '').isNotEmpty) {
          families[span.text!] = span.style?.fontFamily;
        }
        return true;
      });
    }

    // The package resolves inline code as `codeConfig.style.merge(parentStyle)`
    // and `merge` gives the argument the last word, so a CodeConfig alone sets
    // `flutter test` in the paragraph's own sans face.
    expect(families['flutter test'], AbTokens.fontMono);
    expect(families['run '], AbTokens.fontSans);
  });

  testWidgets('gives every code fence a copy button', (tester) async {
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: '```bash\nnpm run setup\n```\n',
          size: 27,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('renders a table rather than a run of pipes', (tester) async {
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: '| Part | Role |\n|---|---|\n| Bridge | PTY |\n',
          size: 44,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Table), findsOneWidget);
  });

  // A README wrapped at 80 columns is one paragraph, as GitHub and VS Code
  // render it — not a stack of half-lines.
  testWidgets('soft-wrapped lines read as one paragraph', (tester) async {
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: 'Sample project bundled so the app has\nsomething to show.\n',
          size: 60,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('has something to show', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a hard break (two trailing spaces) still breaks', (tester) async {
    await tester.pumpWidget(
      host(
        const FileContent(
          path: 'readme.md',
          content: 'first line  \nsecond line\n',
          size: 30,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('first line second line', findRichText: true),
      findsNothing,
    );
  });

  test('joinSoftBreaks eats the continuation indent', () {
    expect(joinSoftBreaks('- item that\n  wraps'), '- item that wraps');
  });

  // Tables lay out as GitHub and VS Code lay them out: natural width when they
  // fit, wrapped columns when they do not, and the source's alignment kept.
  group('tables', () {
    const longRow =
        '| Part | Role |\n|---|---|\n'
        '| Bridge | Runs on the dev machine: terminals, file watching, port '
        'scanning and HTTP tunneling for every project it hosts |\n';

    Future<void> pumpTable(
      WidgetTester tester,
      String content, {
      double width = 800,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 600,
                  child: MarkdownPreview(
                    content: FileContent(
                      path: 'readme.md',
                      content: content,
                      size: content.length,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Like VS Code's preview: a maximised viewer is filled, not left half
    // empty beside a reading-width column.
    testWidgets('prose fills a wide pane', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpTable(tester, 'word ' * 400, width: 1400);
      final paragraph = find.textContaining('word word', findRichText: true);
      expect(tester.getSize(paragraph).width, greaterThan(1300));
    });

    testWidgets('a table that fits keeps its natural width', (tester) async {
      await pumpTable(tester, '| A | B |\n|---|---|\n| 1 | 2 |\n');
      expect(tester.getSize(find.byType(Table)).width, lessThan(300));
    });

    testWidgets('a long column wraps inside a narrow pane instead of running '
        'off it', (tester) async {
      await pumpTable(tester, longRow, width: 320);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Table)).width, lessThanOrEqualTo(320));
      final cell = find.textContaining('Runs on the dev', findRichText: true);
      // Wrapped: taller than a single line of it.
      expect(tester.getSize(cell).height, greaterThan(40));
    });

    testWidgets('headers are bold and follow the column alignment', (
      tester,
    ) async {
      await pumpTable(
        tester,
        '| Name | Count |\n|:---|---:|\n| bridge | 12 |\n',
      );
      final header = tester.widget<RichText>(
        find.textContaining('Name', findRichText: true),
      );
      expect(header.text.toPlainText(), 'Name');
      // The style the glyphs actually get: merged down the span tree to the
      // run that holds the word.
      TextStyle? effective(InlineSpan span, TextStyle? inherited) {
        if (span is! TextSpan) return null;
        final here = inherited?.merge(span.style) ?? span.style;
        if (span.text == 'Name') return here;
        for (final child in span.children ?? const <InlineSpan>[]) {
          final found = effective(child, here);
          if (found != null) return found;
        }
        return null;
      }

      expect(effective(header.text, null)?.fontWeight, FontWeight.w600);

      // `---:` — the number sits against the right edge of its column, and
      // the header above it does too, rather than being centred.
      final countHeader = tester.getRect(find.text('Count', findRichText: true));
      final number = tester.getRect(find.text('12', findRichText: true));
      expect((countHeader.right - number.right).abs(), lessThan(1));
    });
  });
}
