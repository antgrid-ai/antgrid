import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models/stream_open.dart';

/// The five session-stream frame types (mirrors
/// `SESSION_FRAME_TYPES`/`SessionFrameType` in
/// `packages/antgrid-wire/src/peer-protocol.ts` — hand-mirrored, kept in
/// lockstep by the shared vectors fixture, not by any suite that spans both
/// languages).
const String kSessionHello = 'session:hello';
const String kSessionEstablished = 'session:established';
const String kSessionPing = 'session:ping';
const String kSessionPong = 'session:pong';
const String kSessionTakeover = 'session:takeover';
const Set<String> kSessionFrameTypes = {
  kSessionHello,
  kSessionEstablished,
  kSessionPing,
  kSessionPong,
  kSessionTakeover,
};

bool isSessionFrameType(Object? type) =>
    type is String && kSessionFrameTypes.contains(type);

/// Bridge's read cap on a session-stream record (app → bridge). A record is
/// its bare payload, so this equals the app's own outbound record-size
/// refusal threshold exactly. Mirrors `PEER_MAX_RECORD_BYTES`
/// (`packages/antgrid-wire/src/peer-authorization.ts`).
const int kPeerMaxRecordBytes = kStreamProjectAppRecordMaxBytes;

/// The app's read cap on a session-stream record (bridge → app): a whole
/// [kMaxTransferBytes] control-plane record, with no header allowance.
/// Mirrors `PEER_MAX_BRIDGE_RECORD_BYTES`.
const int kPeerMaxBridgeRecordBytes = kMaxTransferBytes;

/// A frame's cross-endpoint identity: the SHA-256 of the payload bytes,
/// lowercase hex, truncated to 24 characters.
///
/// MUST stay byte-identical to `frameIdFor` in `bridge/src/netwatch.ts` —
/// lowercase hex either way. Drift is silent: the join simply matches
/// nothing.
String frameIdOf(Uint8List payload) =>
    sha256.convert(payload).toString().substring(0, 24);

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
