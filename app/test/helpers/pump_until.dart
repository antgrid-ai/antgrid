import 'package:flutter_test/flutter_test.dart';

/// Async work can remain pending while a throttled indicator schedules no frame.
extension PumpUntil on WidgetTester {
  Future<void> pumpUntil(
    bool Function() ready, {
    required String reason,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = binding.clock.fromNowBy(timeout);
    while (!ready()) {
      if (!binding.clock.now().isBefore(deadline)) {
        fail('Timed out waiting for $reason');
      }
      await pump(const Duration(milliseconds: 16));
    }
  }
}
