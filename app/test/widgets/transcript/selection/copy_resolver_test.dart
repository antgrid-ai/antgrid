import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/transcript/selection/block_source.dart';
import 'package:antgrid/widgets/transcript/selection/copy_resolver.dart';

BlockSelection _sel(int order, BlockSource s) =>
    BlockSelection(source: s, order: order);

void main() {
  final md1 = assistantSource('Hello **bold**');
  final md2 = assistantSource('Second *para*');

  test('single block fully selected -> full source', () {
    final out = resolveCopy([_sel(0, md1)], 'Hello bold');
    expect(out.plain, 'Hello bold');
    expect(out.markdown, 'Hello **bold**');
    expect(out.html, contains('<strong>bold</strong>'));
  });

  test('single block, partial selection -> plain is the exact substring, but '
      'Markdown/HTML are still the whole block', () {
    final out = resolveCopy([_sel(0, md1)], 'bold');
    expect(out.plain, 'bold');
    expect(out.markdown, 'Hello **bold**');
    expect(out.html, contains('<strong>bold</strong>'));
  });

  test('tiny native selection inside a multi-block message still yields the '
      'whole-block Markdown/HTML (regression: must not degrade to plain)', () {
    // The native selection offsets never line up with the rebuilt source, so a
    // "full block?" comparison used to misfire and drop every rich/Markdown
    // copy to plain. Whole-block source is emitted regardless of range size.
    final multi = assistantSource('Para one.\n\nPara two.');
    final out = resolveCopy([_sel(0, multi)], 'Para');
    expect(out.plain, 'Para');
    expect(out.markdown, 'Para one.\n\nPara two.');
    expect(out.html, contains('<p>Para one.</p>'));
    expect(out.html, contains('<p>Para two.</p>'));
  });

  test('crossing two blocks -> both full, joined', () {
    final out = resolveCopy(
      [_sel(0, md1), _sel(1000, md2)],
      'bold\nSecond',
    );
    expect(out.plain, 'bold\nSecond');
    expect(out.markdown, 'Hello **bold**\n\nSecond *para*');
    expect(out.html, contains('<strong>bold</strong>'));
    expect(out.html, contains('<em>para</em>'));
  });

  test('no touched blocks -> plain only', () {
    final out = resolveCopy(const [], 'loose text');
    expect(out.plain, 'loose text');
    expect(out.markdown, 'loose text');
    expect(out.html, '<p>loose text</p>');
  });

  test('outputs are trimmed', () {
    final out = resolveCopy(const [], '  spaced  ');
    expect(out.plain, 'spaced');
    expect(out.markdown, 'spaced');
  });
}
