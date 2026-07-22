import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:antgrid_relay_client/src/pair_verify.dart';

void main() {
  test('verifies signature from agent vectors fixture', () async {
    final raw = await File('../../evals/fixtures/pair-approval-vectors.json').readAsString();
    final v = jsonDecode(raw) as Map<String, dynamic>;
    final args = v['args'] as Map<String, dynamic>;

    final ok = await verifyPairApproval(
      agentEd25519PubkeyB64: v['pubkeyB64'] as String,
      agentDeviceId: args['agentDeviceId'] as String,
      phonePubkey: args['phonePubkey'] as String,
      phoneDeviceId: args['phoneDeviceId'] as String,
      nonce: args['nonce'] as String,
      expiresAt: args['expiresAt'] as String,
      signatureB64: v['signatureB64'] as String,
    );
    expect(ok, true);
  });

  test('rejects tampered signature', () async {
    final raw = await File('../../evals/fixtures/pair-approval-vectors.json').readAsString();
    final v = jsonDecode(raw) as Map<String, dynamic>;
    final args = v['args'] as Map<String, dynamic>;
    final ok = await verifyPairApproval(
      agentEd25519PubkeyB64: v['pubkeyB64'] as String,
      agentDeviceId: args['agentDeviceId'] as String,
      phonePubkey: args['phonePubkey'] as String,
      phoneDeviceId: args['phoneDeviceId'] as String,
      nonce: args['nonce'] as String,
      expiresAt: args['expiresAt'] as String,
      signatureB64: base64Encode(List<int>.filled(64, 0)),
    );
    expect(ok, false);
  });
}
