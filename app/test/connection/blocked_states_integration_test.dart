import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection cancellation remains a distinct control-flow exception', () {
    expect(ConnectionAttemptCancelled(), isA<Exception>());
  });
}
