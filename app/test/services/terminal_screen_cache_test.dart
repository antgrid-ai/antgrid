import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/services/terminal_screen_cache.dart';

TerminalFrameMessage frame(String id, int size) =>
    parseAbMessage({
          'id': 'frame',
          'timestamp': 0,
          'type': 'terminal:frame',
          'terminalId': id,
          'runId': 'run',
          'attachmentId': 'attachment',
          'version': 2,
          'sequence': 1,
          'revision': 1,
          'cols': 80,
          'rows': 24,
          'ansi': 'x' * size,
          'syncTimedOut': false,
          'history': {
            'epoch': 1,
            'firstRowId': 0,
            'nextRowId': 0,
            'status': 'recording',
          },
        })
        as TerminalFrameMessage;

void main() {
  test('hidden frames evict by global LRU count and retained string bytes', () {
    final cache = TerminalScreenCache(maxScreens: 2, maxBytes: 3000);
    final a = Object();
    final b = Object();
    cache.put(a, '1', frame('1', 100));
    cache.put(b, '2', frame('2', 100));
    cache.put(a, '1', cache.take(a, '1')!);
    cache.put(b, '3', frame('3', 100));
    expect(cache.contains(b, '2'), isFalse);
    expect(cache.contains(a, '1'), isTrue);
    cache.put(b, '4', frame('4', 1000));
    expect(cache.bytes, lessThanOrEqualTo(3000));
    expect(cache.length, lessThanOrEqualTo(2));
    cache.put(a, 'oversized', frame('oversized', 3000));
    expect(cache.contains(a, 'oversized'), isFalse);
    cache.removeOwner(b);
    expect(cache.contains(b, '4'), isFalse);
    cache.removeOwner(a);
    expect(cache.bytes, 0);
  });
}
