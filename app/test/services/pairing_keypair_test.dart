import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/util/device_id.dart';

void main() {
  test('baseDeviceUuid strips the project segment', () {
    expect(baseDeviceUuid('uuid-1.proj-a'), 'uuid-1');
    expect(baseDeviceUuid('uuid-1'), 'uuid-1');
  });
}
