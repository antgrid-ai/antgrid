import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

const _domain = 'antgrid.pair-approval.v1';

Uint8List _buildSigBody({
  required String agentDeviceId,
  required String phonePubkey,
  required String phoneDeviceId,
  required String nonce,
  required String expiresAt,
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
  builder.add(utf8.encode(expiresAt));
  return Uint8List.fromList(builder.toBytes());
}

Future<bool> verifyPairApproval({
  required String agentEd25519PubkeyB64,
  required String agentDeviceId,
  required String phonePubkey,
  required String phoneDeviceId,
  required String nonce,
  required String expiresAt,
  required String signatureB64,
}) async {
  final exp = DateTime.tryParse(expiresAt);
  if (exp == null || exp.isBefore(DateTime.now())) return false;

  final body = _buildSigBody(
    agentDeviceId: agentDeviceId,
    phonePubkey: phonePubkey,
    phoneDeviceId: phoneDeviceId,
    nonce: nonce,
    expiresAt: expiresAt,
  );
  final pubBytes = base64.decode(agentEd25519PubkeyB64);
  final pub = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
  final sig = Signature(base64.decode(signatureB64), publicKey: pub);
  return await Ed25519().verify(body, signature: sig);
}
