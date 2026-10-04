import 'dart:math';

import 'package:antgrid/models/command_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('output is reproduced exactly, with no empty block and no CR left at a '
      "block's end, however it is chunked", () {
    final whole = [
      'first line\r\nabc\r\ndef\n\n\n',
      'emoji \u{1F600} line\n',
      'p' * 40,
      '\r' * 20,
      'q' * 50,
      '\r\n',
      'r' * 30,
      '\n\n',
      's' * 60,
      '\r' * 5,
      'unterminated',
    ].join();
    for (final maxChars in [1 << 20, 150]) {
      final one = CommandOutput(blockChars: 16, maxChars: maxChars)
        ..append(whole);
      for (final size in [1, 3, 7]) {
        final reason = 'chunk $size, cap $maxChars';
        final many = CommandOutput(blockChars: 16, maxChars: maxChars);
        for (var i = 0; i < whole.length; i += size) {
          many.append(whole.substring(i, min(i + size, whole.length)));
          for (final block in many.blocks) {
            expect(block, isNotEmpty, reason: reason);
            expect(block.endsWith('\r'), isFalse, reason: reason);
          }
          expect(many.tail, isNotEmpty, reason: reason);
        }
        expect(many.text, one.text, reason: reason);
        expect(many.tail, one.tail, reason: reason);
        if (maxChars > whole.length) {
          expect(many.text, whole, reason: reason);
          expect(many.length, whole.length, reason: reason);
          expect(many.blocks, one.blocks, reason: reason);
          expect(many.blocks.length, greaterThanOrEqualTo(3), reason: reason);
        }
      }
    }
  });

  test('appending leaves earlier blocks untouched and the tail bounded', () {
    final output = CommandOutput(blockChars: 64);
    var i = 0;
    String line() => 'line ${(i++).toString().padLeft(2, '0')}\n';
    while (output.blocks.length < 2) {
      output.append(line());
    }
    final first = output.blocks.first;
    for (var n = 0; n < 30; n++) {
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

  test('an append that seals and trims notifies once; an empty one not at all',
      () {
    final output = CommandOutput(blockChars: 8, maxChars: 16);
    var calls = 0;
    output.addListener(() => calls++);
    output.append('');
    expect(calls, 0);
    output.append('aaaa\nbbbb\ncccc\ndddd\neeee\nffff\n');
    expect(calls, 1);
    expect(output.trimmed, isTrue);
  });
}
