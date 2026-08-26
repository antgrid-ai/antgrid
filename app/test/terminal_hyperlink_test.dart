import 'package:antgrid/util/external_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isOpenableTerminalHyperlink', () {
    test('accepts web links', () {
      expect(isOpenableTerminalHyperlink('https://example.com'), isTrue);
      expect(isOpenableTerminalHyperlink('http://example.com/a?b=1'), isTrue);
      expect(isOpenableTerminalHyperlink('HTTPS://Example.com'), isTrue);
      expect(isOpenableTerminalHyperlink('  https://example.com  '), isTrue);
    });

    // An OSC 8 payload is written by whatever runs in the terminal, so these
    // are reachable by any program that can print, on a single tap.
    test('refuses non-web schemes', () {
      expect(isOpenableTerminalHyperlink('file:///etc/passwd'), isFalse);
      expect(isOpenableTerminalHyperlink('mailto:a@b.com'), isFalse);
      expect(isOpenableTerminalHyperlink('javascript:alert(1)'), isFalse);
      expect(isOpenableTerminalHyperlink('antgrid://open/project'), isFalse);
      expect(isOpenableTerminalHyperlink('vscode://file/C:/secret'), isFalse);
    });

    test('refuses schemeless and hostless input', () {
      expect(isOpenableTerminalHyperlink(''), isFalse);
      expect(isOpenableTerminalHyperlink('example.com'), isFalse);
      expect(isOpenableTerminalHyperlink('https://'), isFalse);
      expect(isOpenableTerminalHyperlink('/etc/passwd'), isFalse);
    });
  });
}
