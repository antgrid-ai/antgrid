import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models/stream_open.dart';

const int peerFrameVersion = 0x04;
const int peerFrameFixedPrefix = 4;
const int maxPeerFrameHeaderBytes = 1024;

/// Peer-frame header `type` values. The header carries no other
/// discriminator (§1.1): a `"session"` record is a bare session frame
/// (`session:hello`, `established`, `ping`, `pong`), and a `"message"`
/// record is the bare JSON of one control-plane `AbMessage`. The JSON
/// `type` cannot tell the two apart on its own — `ping`, `pong` and the
/// whole `session:*` family exist as `AbMessage` literals too.
const String kPeerFrameSession = 'session';
const String kPeerFrameMessage = 'message';

/// Bridge's read cap on a session-stream record (app → bridge): the app's
/// outbound record-size refusal threshold plus the peer-frame header and
/// length-prefix overhead. Mirrors `PEER_MAX_RECORD_BYTES`
/// (`packages/antgrid-wire/src/peer-authorization.ts`) — unchanged in value
/// from before Stage A.
const int kPeerMaxRecordBytes =
    kStreamProjectAppRecordMaxBytes + maxPeerFrameHeaderBytes + peerFrameFixedPrefix;

/// The app's read cap on a session-stream record (bridge → app): a whole
/// [kMaxTransferBytes] control-plane record plus the same overhead. Mirrors
/// `PEER_MAX_BRIDGE_RECORD_BYTES`.
const int kPeerMaxBridgeRecordBytes =
    kMaxTransferBytes + maxPeerFrameHeaderBytes + peerFrameFixedPrefix;

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
  if (payload.length > kMaxTransferBytes) {
    throw FrameException(
      FrameErrorReason.payloadTooLarge,
      'Payload ${payload.length} bytes > $kMaxTransferBytes',
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
  if (payloadLength > kMaxTransferBytes) {
    throw FrameException(
      FrameErrorReason.payloadTooLarge,
      'Payload $payloadLength bytes > $kMaxTransferBytes',
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
  final type = header['type'];
  if (header.length != 1 ||
      (type != kPeerFrameSession && type != kPeerFrameMessage)) {
    throw FrameException(
      FrameErrorReason.badHeader,
      'Invalid peer frame header',
    );
  }
  return {'type': type};
}

/// UTF-8 byte length of [s] without encoding it. A record-size check wants a
/// count, and `utf8.encode(s).length` allocates a full copy of a multi-MB
/// message to produce one — ~25x the cost of this scan on ASCII. Mirrors the
/// bridge's `Buffer.byteLength(data, "utf8")`, including Dart's substitution
/// of U+FFFD (3 bytes) for an unpaired surrogate, so both ends agree on one
/// message's size.
int utf8ByteLength(String s) {
  // Every code unit is worth at least one byte; the loop adds only the excess.
  var bytes = s.length;
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u < 0x80) continue;
    if (u < 0x800) {
      bytes += 1;
      continue;
    }
    if (u >= 0xd800 && u < 0xdc00 && i + 1 < s.length) {
      final low = s.codeUnitAt(i + 1);
      if (low >= 0xdc00 && low < 0xe000) {
        bytes += 2; // surrogate PAIR: 2 code units -> 4 bytes
        i++;
        continue;
      }
    }
    // BMP char, or an unpaired surrogate the encoder replaces with U+FFFD —
    // 3 bytes either way.
    bytes += 2;
  }
  return bytes;
}
