import 'package:antgrid/design/ab_theme.dart';
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
}
