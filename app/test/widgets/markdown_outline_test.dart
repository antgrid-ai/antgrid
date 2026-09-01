import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:antgrid/widgets/markdown_outline.dart';

HeadingNode _heading(HeadingConfig config, List<SpanNode> children) {
  final node = HeadingNode(config, WidgetVisitor());
  for (final child in children) {
    node.accept(child);
  }
  return node;
}

Toc _toc(int widgetIndex, {HeadingConfig config = const H2Config()}) => Toc(
  node: _heading(config, [TextNode(text: 'Heading $widgetIndex')]),
  widgetIndex: widgetIndex,
);

void main() {
  group('activeOutlineIndex', () {
    final headings = [_toc(0), _toc(4), _toc(9)];

    test('marks the section the reader is inside, not the next one', () {
      // Body between the second and third heading.
      expect(activeOutlineIndex(headings, 6), 1);
    });

    test('marks a heading the moment it reaches the top', () {
      expect(activeOutlineIndex(headings, 9), 2);
    });

    test('marks the first heading above the document body', () {
      expect(activeOutlineIndex(headings, 0), 0);
    });

    test('holds the last heading past the end of the document', () {
      expect(activeOutlineIndex(headings, 40), 2);
    });

    test('marks the first heading for a preamble above it', () {
      // A document opening with body text puts widget 0 before any heading.
      expect(activeOutlineIndex([_toc(3), _toc(8)], 0), 0);
    });
  });

  group('markdownHeadingText', () {
    test('reads plain heading text', () {
      final node = _heading(const H1Config(), [TextNode(text: 'Architecture')]);
      expect(markdownHeadingText(node), 'Architecture');
    });

    test('keeps inline code, which carries its text in a field', () {
      final node = _heading(const H3Config(), [
        TextNode(text: 'Use '),
        CodeNode('copyWith', const CodeConfig()),
        TextNode(text: ' carefully'),
      ]);
      expect(markdownHeadingText(node), 'Use copyWith carefully');
    });

    test('flattens nested emphasis', () {
      final emphasis = ConcreteElementNode(tag: 'em')
        ..accept(TextNode(text: 'Never'));
      final node = _heading(const H2Config(), [
        emphasis,
        TextNode(text: ' cache this'),
      ]);
      expect(markdownHeadingText(node), 'Never cache this');
    });
  });
}
