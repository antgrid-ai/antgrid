import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int _frameVersion = 0x02;
const int _fixedPrefix = 4; // version byte + kind byte + u16 header length
const int _maxHeaderLen = 1024;

/// Route-frame kind byte. Meaningful to the two ENDPOINTS only: the relay
/// forwards route frames opaquely (it parses the header for `to`/`channel` and
/// never interprets `kind`). Endpoints dispatch on it instead of try-parsing
/// payload plaintext — `handshake` admits exactly the two E2E handshake
/// messages, everything else must arrive `sealed`.
enum FrameKind {
  sealed(0x00),
  handshake(0x01);

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
  badJson,
}

class FrameException implements Exception {
  final FrameErrorReason reason;
  final String message;
  FrameException(this.reason, this.message);

  @override
  String toString() => 'FrameException(${reason.name}): $message';
}

/// Sealed framing is `nonce(12) || ciphertext || tag(16)` — see e2e/transport.dart.
const int _nonceLength = 12;

/// A frame's cross-endpoint identity.
///
/// A sealed payload opens with a per-seal RANDOM nonce, and the relay forwards
/// the payload byte-for-byte, so that nonce is already a unique id for this
/// exact frame that BOTH endpoints can compute — no wire change, no header
/// space, no key material. It is what lets a capture taken here be joined
/// against one taken on the agent, closing the gap `AgentTransport.droppedFrames`
/// documents: the route header carries no message id, so a dropped frame is
/// otherwise unidentifiable.
///
/// Plaintext frames (kind-1 handshake) carry no nonce and are rare enough that
/// hashing them costs nothing.
///
/// MUST stay byte-identical to `frameIdFor` in `bridge/src/netwatch.ts` —
/// lowercase hex either way, and a 24-char hash prefix. Drift is silent: the
/// join simply matches nothing.
String frameIdOf(Uint8List payload, FrameKind kind) {
  if (kind == FrameKind.sealed && payload.length >= _nonceLength) {
    final buf = StringBuffer();
    for (var i = 0; i < _nonceLength; i++) {
      buf.write(payload[i].toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
  return sha256.convert(payload).toString().substring(0, 24);
}

// `kind` is deliberately required (no default): every call site must state
// what it is sending — a `sealed` default would let a future handshake path
// silently mislabel its frames.
Uint8List encodeRouteFrame(
  Map<String, dynamic> header,
  Uint8List payload,
  FrameKind kind,
) {
  final headerBytes = utf8.encode(jsonEncode(header));
  if (headerBytes.length > _maxHeaderLen) {
    throw FrameException(
      FrameErrorReason.headerTooLarge,
      'Header ${headerBytes.length} bytes > $_maxHeaderLen',
    );
  }
  final total = _fixedPrefix + headerBytes.length + payload.length;
  final frame = Uint8List(total);
  frame[0] = _frameVersion;
  frame[1] = kind.wireValue;
  ByteData.view(frame.buffer).setUint16(2, headerBytes.length, Endian.big);
  frame.setRange(_fixedPrefix, _fixedPrefix + headerBytes.length, headerBytes);
  frame.setRange(_fixedPrefix + headerBytes.length, total, payload);
  return frame;
}

/// Decodes a binary route frame.
///
/// The returned `payload` is a copy (via `sublist`), safe to retain past the
/// current tick.
({Map<String, dynamic> header, Uint8List payload, FrameKind kind})
decodeRouteFrame(Uint8List buf) {
  if (buf.length < _fixedPrefix) {
    throw FrameException(
      FrameErrorReason.truncated,
      'Frame shorter than $_fixedPrefix bytes',
    );
  }
  if (buf[0] != _frameVersion) {
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
  if (headerLen > _maxHeaderLen) {
    throw FrameException(
      FrameErrorReason.headerTooLarge,
      'Header length $headerLen > $_maxHeaderLen',
    );
  }
  if (_fixedPrefix + headerLen > buf.length) {
    throw FrameException(
      FrameErrorReason.truncated,
      'Header extends past frame end',
    );
  }
  final headerBytes = buf.sublist(_fixedPrefix, _fixedPrefix + headerLen);
  Map<String, dynamic> header;
  try {
    final decoded = jsonDecode(utf8.decode(headerBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Header is not a JSON object');
    }
    header = decoded;
  } catch (e) {
    throw FrameException(
      FrameErrorReason.badJson,
      'Header JSON parse failed: $e',
    );
  }
  final payload = Uint8List.fromList(buf.sublist(_fixedPrefix + headerLen));
  return (header: header, payload: payload, kind: kind);
}
