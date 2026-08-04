import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/util/external_open_target.dart';

void main() {
  group('ExternalOpenTarget.uriFor', () {
    test('reshapes a Windows path into the editor scheme form', () {
      final uri = ExternalOpenTarget.vscode.uriFor(r'C:\Users\dev\repo');
      expect(uri.toString(), 'vscode://file/C:/Users/dev/repo');
    });

    test('leaves a POSIX path absolute', () {
      final uri = ExternalOpenTarget.cursor.uriFor('/home/dev/repo');
      expect(uri.toString(), 'cursor://file/home/dev/repo');
    });

    test('percent-encodes a directory name with spaces', () {
      final uri = ExternalOpenTarget.windsurf.uriFor(r'C:\my repo\src');
      expect(uri.toString(), 'windsurf://file/C:/my%20repo/src');
    });

    // The whole point of going through a URI: a path that would need escaping
    // on a command line is just data here.
    test('carries shell metacharacters without escaping them', () {
      final uri = ExternalOpenTarget.vscode.uriFor('/tmp/a&b`c/repo');
      expect(Uri.decodeFull(uri.path), '/tmp/a&b`c/repo');
    });

    test('the file manager target uses the file scheme', () {
      expect(ExternalOpenTarget.fileManager.uriFor('/home/dev/repo').scheme, 'file');
    });
  });

  test('only the file manager is unprobed — every editor declares a scheme', () {
    final unprobed = ExternalOpenTarget.values.where((t) => t.scheme == null);
    expect(unprobed, [ExternalOpenTarget.fileManager]);
  });
}
