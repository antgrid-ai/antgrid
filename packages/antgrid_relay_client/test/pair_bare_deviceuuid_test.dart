import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:antgrid_relay_client/src/pair_verify.dart';

// Mirrors _buildSigBody from pair_verify.dart exactly:
// utf8(domain) ∥ 0x00 ∥ utf8(agentDeviceId) ∥ 0x00 ∥ base64decode(phonePubkey)
// ∥ 0x00 ∥ utf8(phoneDeviceId) ∥ 0x00 ∥ base64decode(nonce) ∥ 0x00 ∥ utf8(expiresAt)
Uint8List _buildBody({
  required String agentDeviceId,
  required String phonePubkey,
  required String phoneDeviceId,
  required String nonce,
  required String expiresAt,
}) {
  const domain = 'antgrid.pair-approval.v1';
  final builder = BytesBuilder();
  builder.add(utf8.encode(domain));
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

void main() {
  // Shared fixture values — same across all cases; only agentDeviceId varies.
  const phonePubkeyB64 = 'AAECBAUGB+gJCgsMDQ4PEBESExQVFhcYGRobHB0eHw=='; // 32 random-ish bytes
  const phoneDeviceId = 'phone-device-id-fixture';
  const nonceB64 = 'MTIzNDU2Nzg5MDEyMzQ='; // 16 bytes base64
  final expiresAt =
      DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String();

  const bareDeviceId = 'uuid-bare';
  const compoundDeviceId = 'uuid-bare.projA';

  late Ed25519 algo;
  late SimpleKeyPair agentKeyPair;
  late String agentPubB64;

  setUp(() async {
    algo = Ed25519();
    agentKeyPair = await algo.newKeyPair();
    final pub = await agentKeyPair.extractPublicKey();
    agentPubB64 = base64.encode(pub.bytes);
  });

  test('positive — bare round-trip: sign bare, verify bare → true', () async {
    final body = _buildBody(
      agentDeviceId: bareDeviceId,
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonceB64,
      expiresAt: expiresAt,
    );
    final sig = await algo.sign(body, keyPair: agentKeyPair);
    final sigB64 = base64.encode(sig.bytes);

    final ok = await verifyPairApproval(
      agentEd25519PubkeyB64: agentPubB64,
      agentDeviceId: bareDeviceId,
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonceB64,
      expiresAt: expiresAt,
      signatureB64: sigB64,
    );
    expect(ok, true);
  });

  test(
      'negative — compound signed / bare expected: sign compound, verify bare → false',
      () async {
    // Sign with compound agentDeviceId
    final body = _buildBody(
      agentDeviceId: compoundDeviceId,
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonceB64,
      expiresAt: expiresAt,
    );
    final sig = await algo.sign(body, keyPair: agentKeyPair);
    final sigB64 = base64.encode(sig.bytes);

    // Verify with bare agentDeviceId — must reject (proves value is load-bearing)
    final ok = await verifyPairApproval(
      agentEd25519PubkeyB64: agentPubB64,
      agentDeviceId: bareDeviceId, // different from what was signed
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonceB64,
      expiresAt: expiresAt,
      signatureB64: sigB64,
    );
    expect(ok, false,
        reason: 'agentDeviceId is part of signed bytes; swapping compound→bare must fail');
  });

  test(
      'negative (symmetric) — bare signed / compound expected: sign bare, verify compound → false',
      () async {
    // Sign with bare agentDeviceId
    final body = _buildBody(
      agentDeviceId: bareDeviceId,
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonceB64,
      expiresAt: expiresAt,
    );
    final sig = await algo.sign(body, keyPair: agentKeyPair);
    final sigB64 = base64.encode(sig.bytes);

    // Verify with compound agentDeviceId — must reject
    final ok = await verifyPairApproval(
      agentEd25519PubkeyB64: agentPubB64,
      agentDeviceId: compoundDeviceId, // different from what was signed
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: phoneDeviceId,
      nonce: nonceB64,
      expiresAt: expiresAt,
      signatureB64: sigB64,
    );
    expect(ok, false,
        reason: 'agentDeviceId is part of signed bytes; swapping bare→compound must fail');
  });
}
