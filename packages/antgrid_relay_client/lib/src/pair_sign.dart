import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _domain = 'antgrid.pair-request.v1';

/// Build the canonical pair-request signature body. Must produce
/// byte-for-byte identical bytes to
/// `bridge/src/pair-request-verify.ts::buildPairRequestSigBody`.
///
/// Layout:
///   "antgrid.pair-request.v1" || 0x00 ||
///   agentDeviceId (utf8)    || 0x00 ||
///   base64Decode(phonePubkey) || 0x00 ||
///   phoneDeviceId (utf8)    || 0x00 ||
///   base64Decode(nonce)     || 0x00 ||
///   requestedAt (utf8 ISO-8601, no trailing 0x00)
Uint8List buildPairRequestSigBody({
  required String agentDeviceId,
  required String phonePubkey,
  required String phoneDeviceId,
  required String nonce,
  required String requestedAt,
}) {
  final builder = BytesBuilder();
  builder.add(utf8.encode(_domain));
  builder.addByte(0);
  builder.add(utf8.encode(agentDeviceId));
  builder.addByte(0);
  builder.add(base64.decode(phonePubkey));
  builder.addByte(0);
  builder.add(utf8.encode(phoneDeviceId));
  builder.addByte(0);
  builder.add(base64.decode(nonce));
  builder.addByte(0);
  builder.add(utf8.encode(requestedAt));
  return Uint8List.fromList(builder.toBytes());
}

/// Sign a pair-request canonical body with the phone's Ed25519 private
/// seed (raw 32 bytes, as stored by `phone_identity.dart`). Returns the
/// 64-byte signature as standard base64.
Future<String> signPairRequest({
  required String agentDeviceId,
  required String phonePubkey,
  required String phoneDeviceId,
  required String nonce,
  required String requestedAt,
  required List<int> privSeed,
}) async {
  if (privSeed.length != 32) {
    throw ArgumentError('privSeed must be 32 bytes, got ${privSeed.length}');
  }
  final body = buildPairRequestSigBody(
    agentDeviceId: agentDeviceId,
    phonePubkey: phonePubkey,
    phoneDeviceId: phoneDeviceId,
    nonce: nonce,
    requestedAt: requestedAt,
  );
  final algo = Ed25519();
  // `newKeyPairFromSeed` deterministically derives the keypair from a raw
  // 32-byte seed. The pubkey it produces must match the `phonePubkey` arg
  // for downstream verification to succeed.
  final kp = await algo.newKeyPairFromSeed(privSeed);
  final sig = await algo.sign(body, keyPair: kp);
  return base64.encode(sig.bytes);
}
