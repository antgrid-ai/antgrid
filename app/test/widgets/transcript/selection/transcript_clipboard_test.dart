import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/transcript/selection/copy_resolver.dart';
import 'package:antgrid/widgets/transcript/selection/transcript_clipboard.dart';

void main() {
  const out = CopyOutput(plain: 'p', markdown: 'm', html: '<p>p</p>');

  test('rich writes html + plain', () {
    final f = formatsFor(CopyKind.rich, out);
    expect(f.map((e) => e.format), [
      ClipboardFormat.html,
      ClipboardFormat.plain,
    ]);
    expect(f.map((e) => e.data), ['<p>p</p>', 'p']);
  });

  test('plain writes plain only', () {
    final f = formatsFor(CopyKind.plain, out);
    expect(f, hasLength(1));
    expect(f.single.format, ClipboardFormat.plain);
    expect(f.single.data, 'p');
  });

  test('markdown writes markdown payload as plain only', () {
    final f = formatsFor(CopyKind.markdown, out);
    expect(f.single.format, ClipboardFormat.plain);
    expect(f.single.data, 'm');
  });

  test('fallback text: markdown kind uses markdown, others use plain', () {
    expect(fallbackText(CopyKind.markdown, out), 'm');
    expect(fallbackText(CopyKind.rich, out), 'p');
    expect(fallbackText(CopyKind.plain, out), 'p');
  });
}
