import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/services/tunnel_body.dart';

void main() {
  test('a non-gzip record is returned unchanged', () {
    final bytes = decodeTunnelBody(
      TunnelBodyRecord(bytes: Uint8List.fromList(utf8.encode('hello')), gzip: false),
    );
    expect(utf8.decode(bytes), 'hello');
  });

  // Each record is an independent gzip member, which is what lets a record be
  // decoded the moment it lands instead of holding inflater state open.
  test('inflates a standalone gzip member', () {
    const source = 'body { color: red; }';
    final bytes = decodeTunnelBody(
      TunnelBodyRecord(
        bytes: Uint8List.fromList(gzip.encode(utf8.encode(source))),
        gzip: true,
      ),
    );
    expect(utf8.decode(bytes), source);
  });

  test('a gzip record that is not a gzip member throws FormatException', () {
    expect(
      () => decodeTunnelBody(
        TunnelBodyRecord(bytes: Uint8List.fromList(utf8.encode('plain')), gzip: true),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
