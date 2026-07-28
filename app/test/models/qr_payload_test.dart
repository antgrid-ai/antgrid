import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/qr_payload.dart';

void main() {
  test('parses a coordinates-only URI with no p= parameter', () {
    final uri = 'antgrid://pair?v=1&r=${base64Url.encode(utf8.encode('wss://r'))}'
        '&d=dev-1&e=${base64Url.encode(List.filled(32, 7))}'
        '&n=${base64Url.encode(utf8.encode('box'))}';
    final qr = QrPayload.parse(uri);
    expect(qr, isNotNull);
    expect(qr!.agentDeviceId, 'dev-1');
  });
}
