import 'package:antgrid/widgets/viewer_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('viewerBasename', () {
    test('takes the last segment of a checkout path', () {
      expect(viewerBasename('lib/widgets/a.dart'), 'a.dart');
    });

    // A backslash is a legal filename character on Linux and macOS, so in a
    // checkout path it is part of the name, not a separator.
    test('keeps a backslash inside a POSIX file name', () {
      expect(viewerBasename(r'docs/notes\v2.txt'), r'notes\v2.txt');
    });

    test('splits a Windows absolute path on backslashes', () {
      expect(viewerBasename(r'C:\Users\me\shot.png'), 'shot.png');
      expect(viewerBasename(r'\\server\share\shot.png'), 'shot.png');
    });
  });
}
