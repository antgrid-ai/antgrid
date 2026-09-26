import 'package:test/test.dart';
import 'package:antgrid_relay_client/src/frame.dart';

void main() {
  group('isSessionFrameType', () {
    for (final type in kSessionFrameTypes) {
      test('accepts $type', () {
        expect(isSessionFrameType(type), isTrue);
      });
    }

    for (final rejected in [
      'ping',
      'pong',
      'established',
      'session-takeover',
      'session:list',
      null,
      42,
    ]) {
      test('rejects ${rejected ?? 'null'}', () {
        expect(isSessionFrameType(rejected), isFalse);
      });
    }
  });
}
