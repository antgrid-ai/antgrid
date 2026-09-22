import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Uses each test's in-memory relay as an explicit payload double, without
/// provisioning native libraries or making HTTP authorization requests.
class TestPeerRuntime extends PeerRuntime {
  TestPeerRuntime()
    : super(
        record: DeviceRecord(
          userId: 'test',
          deviceUuid: 'test',
          clientId: 'test',
          clientSecret: 'test',
          ed25519Pub: base64Encode(Uint8List(32)),
          ed25519Priv: base64Encode(Uint8List(32)),
          x25519Pub: '',
          x25519Priv: '',
          endpointSecret: base64Encode(Uint8List(32)),
        ),
        licenseApiUrl: 'https://unused.invalid',
        mintToken: () async => 'test',
      );

  @override
  void retain() {}
  @override
  void release() {}
  @override
  Future<PeerLink> connect({
    required PeerConnectionAttempt attempt,
    required RelayService relay,
    required String machineDeviceId,
    required String machinePublicKey,
  }) async {
    return relay;
  }
}
