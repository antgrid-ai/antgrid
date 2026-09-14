import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/services/tunnel_body.dart';

void main() {
  test('decodes a plain base64 slice', () {
    final bytes = decodeTunnelSlice(base64Encode(utf8.encode('hello')), 'base64');
    expect(utf8.decode(bytes), 'hello');
  });

  // Each gzip slice is an independent member, which is what lets a slice be
  // decoded the moment it lands instead of holding inflater state open.
  test('inflates a standalone gzip-base64 member', () {
    const source = 'body { color: red; }';
    final bytes = decodeTunnelSlice(
      base64Encode(gzip.encode(utf8.encode(source))),
      kTunnelGzipEncoding,
    );
    expect(utf8.decode(bytes), source);
  });

  test('an unknown encoding throws naming the value', () {
    expect(
      () => decodeTunnelSlice('aGk=', 'utf8'),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', contains('utf8')),
      ),
    );
  });

  test('undecodable base64 throws', () {
    expect(() => decodeTunnelSlice('not base64!!', 'base64'),
        throwsA(isA<FormatException>()));
  });

  test('a gzip slice that is not a gzip member throws', () {
    expect(
      () => decodeTunnelSlice(base64Encode(utf8.encode('plain')), kTunnelGzipEncoding),
      throwsA(isA<FormatException>()),
    );
  });
}
