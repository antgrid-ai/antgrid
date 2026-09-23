import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'frag.dart';

const int peerFrameVersion = 0x04;
const int peerFrameFixedPrefix = 4;
const int maxPeerFrameHeaderBytes = 1024;

/// Peer-frame kind byte. QUIC/TLS between the two lease-authorized endpoints
/// is the confidentiality layer now, so the byte carries a single value —
/// kept, with the header layout, so framing does not churn twice before Stage
/// A redesigns it.
enum FrameKind {
  message(0x00);

  final int wireValue;
  const FrameKind(this.wireValue);

  static FrameKind? fromWire(int value) {
    for (final k in FrameKind.values) {
      if (k.wireValue == value) return k;
    }
    return null;
  }
}

enum FrameErrorReason {
  badVersion,
  badKind,
  truncated,
  headerTooLarge,
  payloadTooLarge,
  badJson,
  badHeader,
}

class FrameException implements Exception {
  final FrameErrorReason reason;
  final String message;
  FrameException(this.reason, this.message);

  @override
  String toString() => 'FrameException(${reason.name}): $message';
}

/// A frame's cross-endpoint identity: the SHA-256 of the payload bytes,
/// lowercase hex, truncated to 24 characters.
///
/// MUST stay byte-identical to `frameIdFor` in `bridge/src/netwatch.ts` —
/// lowercase hex either way. Drift is silent: the join simply matches
/// nothing.
String frameIdOf(Uint8List payload) =>
    sha256.convert(payload).toString().substring(0, 24);

Uint8List encodePeerFrame(Map<String, dynamic> header, Uint8List payload) {
  final parsedHeader = _validatePeerHeader(header);
  if (payload.length > kMaxFramePayload) {
    throw FrameException(
      FrameErrorReason.payloadTooLarge,
      'Payload ${payload.length} bytes > $kMaxFramePayload',
    );
  }
  final headerBytes = utf8.encode(jsonEncode(parsedHeader));
  if (headerBytes.length > maxPeerFrameHeaderBytes) {
    throw FrameException(
      FrameErrorReason.headerTooLarge,
      'Header ${headerBytes.length} bytes > $maxPeerFrameHeaderBytes',
    );
  }
  final total = peerFrameFixedPrefix + headerBytes.length + payload.length;
  final frame = Uint8List(total);
  frame[0] = peerFrameVersion;
  frame[1] = FrameKind.message.wireValue;
  ByteData.view(frame.buffer).setUint16(2, headerBytes.length, Endian.big);
  frame.setRange(
    peerFrameFixedPrefix,
    peerFrameFixedPrefix + headerBytes.length,
    headerBytes,
  );
  frame.setRange(peerFrameFixedPrefix + headerBytes.length, total, payload);
  return frame;
}

/// Decodes a binary peer frame.
///
/// The returned `payload` is a copy (via `sublist`), safe to retain past the
/// current tick.
({Map<String, dynamic> header, Uint8List payload}) decodePeerFrame(
  Uint8List buf,
) {
  if (buf.length < peerFrameFixedPrefix) {
    throw FrameException(
      FrameErrorReason.truncated,
      'Frame shorter than $peerFrameFixedPrefix bytes',
    );
  }
  if (buf[0] != peerFrameVersion) {
    throw FrameException(
      FrameErrorReason.badVersion,
      'Unknown frame version: 0x${buf[0].toRadixString(16)}',
    );
  }
  final kind = FrameKind.fromWire(buf[1]);
  if (kind == null) {
    throw FrameException(
      FrameErrorReason.badKind,
      'Unknown frame kind: 0x${buf[1].toRadixString(16)}',
    );
  }
  final view = ByteData.view(buf.buffer, buf.offsetInBytes);
  final headerLen = view.getUint16(2, Endian.big);
  if (headerLen > maxPeerFrameHeaderBytes) {
    throw FrameException(
      FrameErrorReason.headerTooLarge,
      'Header length $headerLen > $maxPeerFrameHeaderBytes',
    );
  }
  if (peerFrameFixedPrefix + headerLen > buf.length) {
    throw FrameException(
      FrameErrorReason.truncated,
      'Header extends past frame end',
    );
  }
  final payloadLength = buf.length - peerFrameFixedPrefix - headerLen;
  if (payloadLength > kMaxFramePayload) {
    throw FrameException(
      FrameErrorReason.payloadTooLarge,
      'Payload $payloadLength bytes > $kMaxFramePayload',
    );
  }
  final headerBytes = buf.sublist(
    peerFrameFixedPrefix,
    peerFrameFixedPrefix + headerLen,
  );
  Map<String, dynamic> header;
  try {
    final decoded = jsonDecode(utf8.decode(headerBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Header is not a JSON object');
    }
    header = _validatePeerHeader(decoded);
  } on FrameException {
    rethrow;
  } catch (e) {
    throw FrameException(
      FrameErrorReason.badJson,
      'Header JSON parse failed: $e',
    );
  }
  final payload = Uint8List.fromList(
    buf.sublist(peerFrameFixedPrefix + headerLen),
  );
  return (header: header, payload: payload);
}

Map<String, dynamic> _validatePeerHeader(Map<String, dynamic> header) {
  final channel = header['channel'];
  if (header.length != 2 ||
      header['type'] != 'message' ||
      (channel != 'control' && channel != 'preview')) {
    throw FrameException(
      FrameErrorReason.badHeader,
      'Invalid peer frame header',
    );
  }
  return {'type': 'message', 'channel': channel};
}
