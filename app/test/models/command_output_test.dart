import 'package:antgrid/models/command_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reproduces appended output exactly across block boundaries', () {
    final output = CommandOutput(blockChars: 16, maxChars: 1 << 20);
    final chunks = [
      'first line\n',
      'second line\r\n',
      'abc\r',
      '\ndef\n',
      '\n\n\n',
      'a line that is much longer than sixteen chars\n',
      'emoji \u{1F600} line\n',
      'tail\r\nmore\r\n',
      'x' * 40,
      '\nend\n',
      'unterminated',
    ];
    var all = '';
    for (final chunk in chunks) {
      output.append(chunk);
      all += chunk;
      expect(output.text, all);
      expect(output.length, all.length);
      for (final block in output.blocks) {
        expect(block, isNotEmpty);
        expect(block.endsWith('\r'), isFalse);
      }
      expect(output.tail, isNotEmpty);
    }
    expect(output.blocks.length, greaterThanOrEqualTo(3));
  });

  test('appending leaves earlier blocks untouched', () {
    final output = CommandOutput(blockChars: 64);
    var i = 0;
    String line() => 'line ${(i++).toString().padLeft(2, '0')}\n';
    while (output.blocks.length < 2) {
      output.append(line());
    }
    final first = output.blocks.first;
    for (var n = 0; n < 200; n++) {
      output.append(line());
      expect(identical(output.blocks.first, first), isTrue);
      expect(output.tail.length, lessThanOrEqualTo(64 + 8));
    }
  });

  test('drops whole oldest blocks past the retention cap and reports the trim',
      () {
    final output = CommandOutput(blockChars: 32, maxChars: 256);
    var all = '';
    for (var i = 0; i < 100; i++) {
      final line = 'numbered line $i\n';
      output.append(line);
      all += line;
    }
    expect(output.trimmed, isTrue);
    expect(output.length, lessThanOrEqualTo(256));
    expect(output.text, all.substring(all.length - output.text.length));
    expect(all[all.length - output.text.length - 1], '\n');
    expect(output.firstBlockSeq, greaterThan(0));
  });

  test('an unterminated line past the cap keeps its newest characters', () {
    final output = CommandOutput(maxChars: 100);
    output.append('${'x' * 99}\u{1F600}${'y' * 99}');
    expect(output.trimmed, isTrue);
    expect(output.text, 'y' * 99);
    expect(output.length, 99);
    expect(output.text.codeUnitAt(0), isNot(0xDE00));
  });

  test('notifies once per append and ignores empty appends', () {
    final output = CommandOutput();
    var calls = 0;
    output.addListener(() => calls++);
    output.append('a');
    expect(calls, 1);
    output.append('');
    expect(calls, 1);

    final small = CommandOutput(blockChars: 8, maxChars: 16);
    var smallCalls = 0;
    small.addListener(() => smallCalls++);
    small.append('aaaa\nbbbb\ncccc\ndddd\neeee\nffff\n');
    expect(smallCalls, 1);
  });
}
