import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  test('parses terminal:size into TerminalSizeMessage', () {
    final msg = parseAbMessage({
      'type': 'terminal:size',
      'id': 'x',
      'timestamp': 1,
      'terminalId': 't1',
      'cols': 100,
      'rows': 30,
      'driverClientId': 'dev-abc',
    });
    expect(msg, isA<TerminalSizeMessage>());
    final size = msg as TerminalSizeMessage;
    expect(size.terminalId, 't1');
    expect(size.cols, 100);
    expect(size.rows, 30);
    expect(size.driverClientId, 'dev-abc');
  });
}
