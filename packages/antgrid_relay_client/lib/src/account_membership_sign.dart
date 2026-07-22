import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _domain = 'antgrid.account-membership.v1';

/// Build the canonical account-membership signature body. Produces
/// byte-for-byte identical output to the TypeScript `buildMembershipSigBody`
/// in `bridge/src/account-membership-verify.ts`.
///
/// Layout:
///   "antgrid.account-membership.v1" || 0x00 ||
///   agentDeviceId (utf8)            || 0x00 ||
///   phoneDeviceId (utf8)            || 0x00 ||
///   base64Decode(phonePubkey)       || 0x00 ||
///   base64Decode(accountDevicePubkey) || 0x00 ||
///   base64Decode(nonce)   (no trailing 0x00)
List<int> buildMembershipSigBody({
  required String agentDeviceId,
  required String phoneDeviceId,
  required String phonePubkey,
  required String accountDevicePubkey,
  required String nonce,
}) {
  final b = BytesBuilder();
  b.add(utf8.encode(_domain));
  b.addByte(0);
  b.add(utf8.encode(agentDeviceId));
  b.addByte(0);
  b.add(utf8.encode(phoneDeviceId));
  b.addByte(0);
  b.add(base64.decode(phonePubkey));
  b.addByte(0);
  b.add(base64.decode(accountDevicePubkey));
  b.addByte(0);
  b.add(base64.decode(nonce));
  return Uint8List.fromList(b.toBytes());
}

/// Sign an account-membership canonical body with the given Ed25519 private
/// seed (raw 32 bytes). Returns the 64-byte signature as standard base64.
///
/// [accountDevicePrivSeed] is the 32-byte Ed25519 seed of the account device key.
Future<String> signAccountMembership({
  required String agentDeviceId,
  required String phoneDeviceId,
  required String phonePubkey,
  required String accountDevicePubkey,
  required String nonce,
  required List<int> accountDevicePrivSeed,
}) async {
  if (accountDevicePrivSeed.length != 32) {
    throw ArgumentError(
        'accountDevicePrivSeed must be 32 bytes, got ${accountDevicePrivSeed.length}');
  }
  final body = buildMembershipSigBody(
    agentDeviceId: agentDeviceId,
    phoneDeviceId: phoneDeviceId,
    phonePubkey: phonePubkey,
    accountDevicePubkey: accountDevicePubkey,
    nonce: nonce,
  );
  final kp = await Ed25519().newKeyPairFromSeed(accountDevicePrivSeed);
  final sig = await Ed25519().sign(body, keyPair: kp);
  return base64.encode(sig.bytes);
}
