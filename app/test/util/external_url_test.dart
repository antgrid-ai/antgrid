import 'package:antgrid/util/external_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('terminalFilePath', () {
    test('extracts a POSIX absolute path', () {
      expect(
        terminalFilePath('file:///home/user/project/src/app.ts'),
        '/home/user/project/src/app.ts',
      );
    });

    test('strips the extra leading slash before a Windows drive letter', () {
      expect(
        terminalFilePath('file:///C:/Users/dev/project/main.dart'),
        'C:/Users/dev/project/main.dart',
      );
    });

    test('percent-decodes escaped characters', () {
      expect(
        terminalFilePath('file:///home/user/my%20project/a%26b.txt'),
        '/home/user/my project/a&b.txt',
      );
    });

    test('tolerates a hostname authority (some tools emit one)', () {
      expect(
        terminalFilePath('file://myhost/home/user/project/app.ts'),
        '/home/user/project/app.ts',
      );
    });

    test('returns null for a non-file scheme', () {
      expect(terminalFilePath('https://example.com/app.ts'), isNull);
    });

    test('returns null for an unparseable string', () {
      expect(terminalFilePath('not a uri at all: %zz'), isNull);
    });
  });

  group('terminalBarePath', () {
    test('takes a relative path as written', () {
      expect(terminalBarePath('docs/a.md'), (path: 'docs/a.md', line: null));
    });

    test('takes a Windows drive path, whose drive is not a scheme', () {
      expect(terminalBarePath(r'C:\x\a.md'), (path: r'C:\x\a.md', line: null));
      expect(terminalBarePath('C:/x/a.md'), (path: 'C:/x/a.md', line: null));
    });

    test('reads a line from :12, :12:5 and #L12', () {
      expect(terminalBarePath('src/a.ts:12'), (path: 'src/a.ts', line: 12));
      expect(terminalBarePath('src/a.ts:12:5'), (path: 'src/a.ts', line: 12));
      expect(terminalBarePath('src/a.ts#L12'), (path: 'src/a.ts', line: 12));
      expect(terminalBarePath('src/a.ts#L12-L20'), (path: 'src/a.ts', line: 12));
      expect(terminalBarePath('README.md:12'), (path: 'README.md', line: 12));
    });

    test('drops a heading anchor and an out-of-range line', () {
      expect(terminalBarePath('README.md#install'), (path: 'README.md', line: null));
      expect(terminalBarePath('a.ts:0'), (path: 'a.ts', line: null));
    });

    test('decodes escapes, and keeps a % that starts none', () {
      expect(terminalBarePath('my%20notes.md'), (path: 'my notes.md', line: null));
      expect(terminalBarePath('100%.md'), (path: '100%.md', line: null));
    });

    test('returns null for anything with a scheme, or naming no file', () {
      for (final uri in [
        'https://example.com/a.md',
        'file:///x/a.md',
        'antgrid-path:?p=a&b=r',
        'mailto:a@b.c',
        '//example.com/a.md',
        '#install',
        '?q=1',
        '   ',
      ]) {
        expect(terminalBarePath(uri), isNull, reason: uri);
      }
    });
  });
}
