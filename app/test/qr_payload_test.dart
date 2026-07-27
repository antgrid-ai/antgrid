import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/qr_payload.dart';

void main() {
  test('parses v1 with e, tolerating the retired p param', () {
    // The bridge no longer emits `p=` (bridge/src/connect-uri.ts), but an
    // already-printed or screenshotted QR from before that change may still
    // carry it, and its presence must never make a payload unparseable.
    final uri =
        'antgrid://pair?v=1&r=${base64Url.encode(utf8.encode("wss://r"))}'
        '&d=agent-1'
        '&e=${base64Url.encode(List.filled(32, 2))}'
        '&p=code-xyz'
        '&n=${base64Url.encode(utf8.encode("Project"))}';
    final p = QrPayload.parse(uri);
    expect(p, isNotNull);
    expect(p!.agentEd25519PublicKey, isNotNull);
    expect(p.agentDeviceId, 'agent-1');
  });

  test('parses v1 with p= absent', () {
    final uri =
        'antgrid://pair?v=1&r=${_b64("wss://r")}&d=agent-1'
        '&e=${base64Url.encode(List.filled(32, 2))}'
        '&n=${_b64("Project")}';
    expect(QrPayload.parse(uri)?.agentDeviceId, 'agent-1');
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

  test('an r= that is not a URL falls back to the default relay', () {
    // A bridge banner once emitted the literal "(local mode)" placeholder here;
    // taking it verbatim made the payload undialable with no way back.
    final e = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');
    final uri =
        'antgrid://pair?v=1&r=${_b64("(local mode)")}&d=dev-1&e=$e'
        '&n=${_b64("antgrid")}';
    final p = QrPayload.parse(uri, defaultRelayUrl: 'wss://relay.example');
    expect(p, isNotNull);
    expect(p!.relayUrl, 'wss://relay.example');
  });

  test('an r= that is not a URL with no fallback fails the parse', () {
    final e = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');
    final uri =
        'antgrid://pair?v=1&r=${_b64("(local mode)")}&d=dev-1&e=$e'
        '&n=${_b64("antgrid")}';
    expect(QrPayload.parse(uri), isNull);
    // A blank fallback is no fallback — an empty RELAY_URL define reaches us as
    // '', and a payload built on it carries a relay coordinate that can only
    // fail at dial time.
    expect(QrPayload.parse(uri, defaultRelayUrl: ''), isNull);
    expect(QrPayload.parse(uri, defaultRelayUrl: '   '), isNull);
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
