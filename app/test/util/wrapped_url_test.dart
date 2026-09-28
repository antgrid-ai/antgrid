import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/util/wrapped_url.dart';

void main() {
  const cols = 40;

  test('rejoins a query string an agent TUI wrapped onto the next row', () {
    final lines = [
      '  see https://example.com/path/to/page?a',
      '  =1&b=2#frag',
      '  done',
    ];
    expect(lines[0].length, cols);
    expect(
      extendWrappedUrl('https://example.com/path/to/page?a', lines, cols),
      'https://example.com/path/to/page?a=1&b=2#frag',
    );
  });

  test('follows a URL across several full rows', () {
    final lines = [
      'https://example.com/aaaaaaaaaaaaaaaaaaaa',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      '#!/route',
    ];
    expect(
      extendWrappedUrl(lines[0], lines, cols),
      '${lines[0]}${lines[1]}#!/route',
    );
  });

  test('a URL ending a short row is left alone', () {
    final lines = ['open https://example.com/x', 'next line of prose'];
    expect(
      extendWrappedUrl('https://example.com/x', lines, cols),
      'https://example.com/x',
    );
  });

  test('a second URL on the next row is not appended', () {
    final lines = [
      'https://example.com/aaaaaaaaaaaaaaaaaaaa',
      'https://other.example/',
    ];
    expect(extendWrappedUrl(lines[0], lines, cols), lines[0]);
  });

  test('a closing parenthesis is kept while the URL opened it', () {
    const head = 'https://en.example.org/wiki/Foo_(programming_lang';
    const row = '  $head';
    // The pane is exactly as wide as the first row, so it reaches the edge.
    final wide = row.length;
    expect(
      extendWrappedUrl(head, [row, 'uage)'], wide),
      'https://en.example.org/wiki/Foo_(programming_language)',
    );
    // The sentence's own `)` and `.` still go.
    expect(
      extendWrappedUrl(head, [row, 'uage)).'], wide),
      'https://en.example.org/wiki/Foo_(programming_language)',
    );
  });

  test('trailing sentence punctuation is dropped from the joined URL', () {
    final lines = ['  https://example.com/path/to/page?query', '=1.'];
    expect(
      extendWrappedUrl('https://example.com/path/to/page?query', lines, cols),
      'https://example.com/path/to/page?query=1',
    );
  });
}
