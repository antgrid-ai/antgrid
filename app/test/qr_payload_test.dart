import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/qr_payload.dart';

void main() {
  test('parses v1 with e and p params', () {
    final uri =
        'antgrid://pair?v=1&r=${base64Url.encode(utf8.encode("wss://r"))}'
        '&d=agent-1'
        '&e=${base64Url.encode(List.filled(32, 2))}'
        '&p=code-xyz'
        '&n=${base64Url.encode(utf8.encode("Project"))}';
    final p = QrPayload.parse(uri);
    expect(p, isNotNull);
    expect(p!.agentEd25519PublicKey, isNotNull);
    expect(p.pairCode, 'code-xyz');
  });

  test('yields the BARE agentDeviceId (no dot) from d=', () {
    final e = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
    final uri =
        'antgrid://pair?v=1&r=${_b64("wss://r")}&d=uuid-bare&e=$e'
        '&p=abc&n=${_b64("antgrid")}';
    final p = QrPayload.parse(uri);
    expect(p, isNotNull);
    expect(p!.agentDeviceId, equals('uuid-bare'));
    expect(p.agentDeviceId, isNot(contains('.')));
  });

  test('rejects v2 (not supported)', () {
    final uri = 'antgrid://pair?v=2&r=&d=&k=&n=';
    expect(QrPayload.parse(uri), isNull);
  });

  test('rejects v3 (not supported)', () {
    final e = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');
    final uri =
        'antgrid://pair?v=3&r=${_b64("wss://r")}&d=dev.proj&k=$e&e=$e'
        '&p=abc&n=${_b64("antgrid")}';
    expect(QrPayload.parse(uri), isNull);
  });

  test('parses h= into hostMachineName', () {
    final e = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');
    final uri =
        'antgrid://pair?v=1&r=${_b64("wss://r")}&d=dev.proj&e=$e'
        '&p=abc&n=${_b64("antgrid")}&h=${_b64("Mac Studio")}';
    final p = QrPayload.parse(uri);
    expect(p!.hostMachineName, 'Mac Studio');
  });

  test('hostMachineName is null when h= absent', () {
    final e = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');
    final uri =
        'antgrid://pair?v=1&r=${_b64("wss://r")}&d=dev.proj&e=$e'
        '&p=abc&n=${_b64("antgrid")}';
    expect(QrPayload.parse(uri)!.hostMachineName, isNull);
  });
}

String _b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
