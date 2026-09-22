import 'package:antgrid/connection/supervisor_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the production ladder exposes only native payload stages', () {
    expect(ConnRung.values, const [
      ConnRung.wanted,
      ConnRung.coords,
      ConnRung.payload,
      ConnRung.established,
    ]);
  });
}
