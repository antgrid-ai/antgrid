import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/markdown_document_config.dart';
import 'package:antgrid/widgets/tasks/markdown_format.dart';
import 'package:antgrid/widgets/tasks/task_body_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _v(String text, int start, [int? end]) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
);

String _selected(TextEditingValue v) =>
    v.text.substring(v.selection.start, v.selection.end);

void main() {
  group('wrap', () {
    test('wraps the selection and keeps it selected', () {
      final out = MarkdownFormat.wrap(_v('make it loud', 8, 12), '**');
      expect(out.text, 'make it **loud**');
      expect(_selected(out), 'loud');
    });

    test('an empty selection inserts a selected placeholder', () {
      final out = MarkdownFormat.wrap(_v('a ', 2), '_');
      expect(out.text, 'a _text_');
      expect(_selected(out), 'text');
    });

    test('an already-wrapped selection is unwrapped', () {
      final out = MarkdownFormat.wrap(_v('make it **loud**', 10, 14), '**');
      expect(out.text, 'make it loud');
      expect(_selected(out), 'loud');
    });

    test('edge spaces stay outside the markers, so it still renders bold', () {
      final out = MarkdownFormat.wrap(_v('make it loud now', 8, 13), '**');
      expect(out.text, 'make it **loud** now');
      expect(_selected(out), 'loud');
    });

    test('a selection that includes its markers is unwrapped', () {
      final out = MarkdownFormat.wrap(_v('a **b** c', 2, 7), '**');
      expect(out.text, 'a b c');
    });

    test('a field never focused acts at the end', () {
      final out = MarkdownFormat.wrap(
        const TextEditingValue(text: 'end'),
        '**',
      );
      expect(out.text, 'end**text**');
    });
  });

  group('toggleTask', () {
    test('flips the indexed box and leaves the others', () {
      const src = '- [ ] one\n- [x] two\n- [ ] three';
      expect(
        MarkdownFormat.toggleTask(src, 0),
        '- [x] one\n- [x] two\n- [ ] three',
      );
      expect(
        MarkdownFormat.toggleTask(src, 1),
        '- [ ] one\n- [ ] two\n- [ ] three',
      );
    });

    test('counts ordered, nested and quoted items like the renderer', () {
      const src = '1. [ ] a\n  * [ ] b\n> - [X] c';
      expect(
        MarkdownFormat.toggleTask(src, 2),
        '1. [ ] a\n  * [ ] b\n> - [ ] c',
      );
    });

    test('skips boxes inside fenced code and plain bullets', () {
      const src = '- plain\n```\n- [ ] code\n```\n- [ ] real';
      expect(
        MarkdownFormat.toggleTask(src, 0),
        '- plain\n```\n- [ ] code\n```\n- [x] real',
      );
    });

    test('an index past the last box changes nothing', () {
      expect(MarkdownFormat.toggleTask('- [ ] only', 1), isNull);
    });
  });

  group('comments', () {
    test('splits prose from template comments, in order', () {
      final parts = MarkdownFormat.splitComments(
        '<!-- read this -->\n## Bug\n<!-- describe it -->\nIt breaks.',
      );
      expect(parts.map((p) => (p.text.trim(), p.isComment)).toList(), [
        ('read this', true),
        ('## Bug', false),
        ('describe it', true),
        ('It breaks.', false),
      ]);
    });

    test('a comment inside fenced code stays code', () {
      const src = '```html\n<!-- keep -->\n```';
      final parts = MarkdownFormat.splitComments(src);
      expect(parts, hasLength(1));
      expect(parts.single.isComment, isFalse);
    });

    test('an unterminated comment runs to the end', () {
      final parts = MarkdownFormat.splitComments('Hi\n<!-- open');
      expect(parts.last.isComment, isTrue);
      expect(parts.last.text, 'open');
    });

    test('boxes inside a comment are not counted', () {
      const src = '<!--\n- [ ] hidden\n-->\n- [ ] shown';
      expect(MarkdownFormat.taskCount(src), 1);
      expect(
        MarkdownFormat.toggleTask(src, 0),
        '<!--\n- [ ] hidden\n-->\n- [x] shown',
      );
    });
  });

  group('linePrefix', () {
    test('prefixes every line the selection touches', () {
      final out = MarkdownFormat.linePrefix(_v('one\ntwo\nthree', 1, 5), '- ');
      expect(out.text, '- one\n- two\nthree');
    });

    test('strips the prefix when every line already has it', () {
      final out = MarkdownFormat.linePrefix(_v('> a\n> b', 0, 7), '> ');
      expect(out.text, 'a\nb');
    });

    test('numbers lines in order, and toggles back off', () {
      final on = MarkdownFormat.linePrefix(
        _v('a\nb', 0, 3),
        '',
        numbered: true,
      );
      expect(on.text, '1. a\n2. b');
      final off = MarkdownFormat.linePrefix(on, '', numbered: true);
      expect(off.text, 'a\nb');
    });

    test('a caret moves with the prefix it gained', () {
      final out = MarkdownFormat.linePrefix(_v('task', 2), '- [ ] ');
      expect(out.text, '- [ ] task');
      expect(out.selection, const TextSelection.collapsed(offset: 8));
    });
  });

  test('code is inline on one line and fenced across several', () {
    expect(MarkdownFormat.code(_v('run x', 4, 5)).text, 'run `x`');
    expect(MarkdownFormat.code(_v('a\nb', 0, 3)).text, '```\na\nb\n```');
  });

  test('link wraps the selection and selects the url to paste over', () {
    final out = MarkdownFormat.link(_v('see docs', 4, 8));
    expect(out.text, 'see [docs](url)');
    expect(_selected(out), 'url');
  });

  testWidgets('the toolbar edits the source and Preview renders it', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'loud');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(body: TaskBodyEditor(controller: controller)),
        ),
      ),
    );
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);

    await tester.tap(find.byTooltip('Bold (Ctrl+B)'));
    await tester.pump();
    expect(controller.text, '**loud**');

    await tester.tap(find.text('PREVIEW'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('loud'), findsWidgets);
    expect(find.textContaining('**'), findsNothing);

    await tester.tap(find.text('WRITE'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a long Preview scrolls inside the box instead of growing it', (
    tester,
  ) async {
    final controller = TextEditingController(
      text: [for (var i = 0; i < 80; i++) '- [ ] Item $i'].join('\n'),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TaskBodyEditor(controller: controller),
            ),
          ),
        ),
      ),
    );
    final writeHeight = tester.getSize(find.byType(TaskBodyEditor)).height;

    await tester.tap(find.text('PREVIEW'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(TaskBodyEditor)).height,
      lessThanOrEqualTo(writeHeight + 1),
    );
    expect(
      find.descendant(
        of: find.byType(TaskBodyEditor),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView && w.scrollDirection == Axis.vertical,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a box in Preview checks it in the source', (
    tester,
  ) async {
    final controller = TextEditingController(text: '- [ ] Design\n- [ ] Build');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(body: TaskBodyEditor(controller: controller)),
        ),
      ),
    );
    await tester.tap(find.text('PREVIEW'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MarkdownTaskMarker).at(1));
    await tester.pumpAndSettle();
    expect(controller.text, '- [ ] Design\n- [x] Build');

    // Still the second box after the rebuild: the index count restarts.
    await tester.tap(find.byType(MarkdownTaskMarker).at(1));
    await tester.pumpAndSettle();
    expect(controller.text, '- [ ] Design\n- [ ] Build');
  });
}
