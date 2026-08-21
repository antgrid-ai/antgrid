// packages/antgrid_relay_client/lib/src/e2e/confirm.dart
// Spec: docs/protocol/e2e-handshake.md §"Key confirmation".
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _agentLabel = 'agent-finished';
const _phoneLabel = 'phone-finished';

Future<Uint8List> _tag(List<int> confirmKey, String label) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(label),
    secretKey: SecretKeyData(confirmKey),
  );
  return Uint8List.fromList(mac.bytes);
}

Future<Uint8List> agentConfirmTagV2(List<int> confirmKey) =>
    _tag(confirmKey, _agentLabel);
Future<Uint8List> phoneConfirmTagV2(List<int> confirmKey) =>
    _tag(confirmKey, _phoneLabel);

/// Constant-time comparison; false on any length mismatch.
bool verifyConfirmTagV2(List<int> expected, List<int> presented) {
  if (expected.length != presented.length) return false;
  var acc = 0;
  for (var i = 0; i < expected.length; i++) {
    acc |= expected[i] ^ presented[i];
  }
  return acc == 0;
}
