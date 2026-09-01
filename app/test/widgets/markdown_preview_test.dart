import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/markdown_outline.dart';
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
}
