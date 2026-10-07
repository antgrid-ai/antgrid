import 'package:antgrid/util/terminal_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePrintedPathLink', () {
    test('decodes the escapes the bridge emits', () {
      expect(
        parsePrintedPathLink(
          'antgrid-path:?p=src%2Fa%20b%5Cc%26d%23e&b=r&k=f',
        )!.path,
        r'src/a b\c&d#e',
      );
    });

    test('decodes %2B to a plus and %25 to a percent', () {
      expect(
        parsePrintedPathLink('antgrid-path:?p=a%2Bb.ts&b=r&k=f')!.path,
        'a+b.ts',
      );
      expect(
        parsePrintedPathLink('antgrid-path:?p=100%25.md&b=r&k=f')!.path,
        '100%.md',
      );
    });

    test('reads base, kind, line and column', () {
      final link = parsePrintedPathLink(
        'antgrid-path:?p=src%2Fa.ts&b=s&k=f&n=12&c=5',
      )!;
      expect(link.path, 'src/a.ts');
      expect(link.base, 's');
      expect(link.kind, PrintedPathKind.file);
      expect(link.line, 12);
      expect(link.column, 5);
    });

    test('maps each kind letter', () {
      PrintedPathKind? kind(String k) =>
          parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=a&k=$k')!.kind;
      expect(kind('f'), PrintedPathKind.file);
      expect(kind('d'), PrintedPathKind.directory);
      expect(kind('i'), PrintedPathKind.image);
    });

    test('accepts every base letter and refuses any other', () {
      for (final b in ['a', 'l', 's', 'r']) {
        expect(
          parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=$b&k=f')!.base,
          b,
        );
      }
      expect(parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=x&k=f'), isNull);
      expect(parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=&k=f'), isNull);
      expect(parsePrintedPathLink('antgrid-path:?p=a%2Fb&k=f'), isNull);
    });

    test('an unknown kind gives a null kind and keeps the link', () {
      final link = parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r&k=z')!;
      expect(link.kind, isNull);
      expect(link.path, 'a/b');
      expect(
        parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r')!.kind,
        isNull,
      );
    });

    test('an out-of-range or malformed line gives a null line', () {
      int? line(String n) =>
          parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r&k=f&n=$n')!.line;
      expect(line('10000000'), 10000000);
      expect(line('10000001'), isNull);
      expect(line('0'), isNull);
      expect(line('-3'), isNull);
      expect(line('1e3'), isNull);
      expect(line('0x10'), isNull);
      expect(line('+5'), isNull);
    });

    test('a column outside its range is dropped, and so is one with no line', () {
      expect(
        parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r&k=f&n=3&c=100000')!
            .column,
        100000,
      );
      expect(
        parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r&k=f&n=3&c=100001')!
            .column,
        isNull,
      );
      expect(
        parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r&k=f&c=5')!.column,
        isNull,
      );
      expect(
        parsePrintedPathLink('antgrid-path:?p=a%2Fb&b=r&k=f&n=99999999&c=5')!
            .column,
        isNull,
      );
    });

    test('a missing or empty path gives null', () {
      expect(parsePrintedPathLink('antgrid-path:?b=r&k=f'), isNull);
      expect(parsePrintedPathLink('antgrid-path:?p=&b=r&k=f'), isNull);
      expect(parsePrintedPathLink('antgrid-path:'), isNull);
    });

    test('an invalid escape stays literal rather than failing', () {
      expect(
        parsePrintedPathLink('antgrid-path:?p=%ZZ&b=r&k=f')!.path,
        '%ZZ',
      );
    });

    test('an escape decoding to invalid UTF-8 gives null without throwing', () {
      expect(parsePrintedPathLink('antgrid-path:?p=%FF&b=r&k=f'), isNull);
    });

    test('a path over the cap gives null, and one at the cap parses', () {
      expect(
        parsePrintedPathLink(
          'antgrid-path:?p=${'a' * kMaxPrintedPathChars}&b=r&k=f',
        )!.path.length,
        kMaxPrintedPathChars,
      );
      expect(
        parsePrintedPathLink(
          'antgrid-path:?p=${'a' * (kMaxPrintedPathChars + 1)}&b=r&k=f',
        ),
        isNull,
      );
    });

    test('requires the scheme prefix exactly', () {
      expect(parsePrintedPathLink('https://e.com/?p=a&b=r&k=f'), isNull);
      expect(parsePrintedPathLink('Antgrid-path:?p=a%2Fb&b=r&k=f'), isNull);
      expect(parsePrintedPathLink(''), isNull);
    });
  });

  group('detectedUrlTarget', () {
    test('returns the inner URL untouched', () {
      expect(
        detectedUrlTarget('antgrid-url:https://e.com/a?b=1#c'),
        'https://e.com/a?b=1#c',
      );
    });

    test('is null without the prefix or without anything after it', () {
      expect(detectedUrlTarget('https://e.com'), isNull);
      expect(detectedUrlTarget('antgrid-url:'), isNull);
      expect(detectedUrlTarget('Antgrid-url:https://e.com'), isNull);
    });
  });

  group('isDetectedTerminalLink', () {
    test('is true for both bridge schemes', () {
      expect(isDetectedTerminalLink('antgrid-path:?p=a&b=r&k=f'), isTrue);
      expect(isDetectedTerminalLink('antgrid-url:https://e.com'), isTrue);
    });

    test('is false for everything else, and case-sensitive', () {
      expect(isDetectedTerminalLink('https://e.com'), isFalse);
      expect(isDetectedTerminalLink('file:///a'), isFalse);
      expect(isDetectedTerminalLink('Antgrid-path:?p=a&b=r&k=f'), isFalse);
      expect(isDetectedTerminalLink(''), isFalse);
    });
  });

  group('printedPathLabel', () {
    test('shows the path, then the line, then the column', () {
      const base = PrintedPathLink(path: 'src/a.ts', base: 'r');
      expect(printedPathLabel(base), 'src/a.ts');
      expect(
        printedPathLabel(
          const PrintedPathLink(path: 'src/a.ts', base: 'r', line: 12),
        ),
        'src/a.ts:12',
      );
      expect(
        printedPathLabel(
          const PrintedPathLink(
            path: 'src/a.ts',
            base: 'r',
            line: 12,
            column: 5,
          ),
        ),
        'src/a.ts:12:5',
      );
    });
  });
}
