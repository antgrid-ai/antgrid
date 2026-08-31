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
}
