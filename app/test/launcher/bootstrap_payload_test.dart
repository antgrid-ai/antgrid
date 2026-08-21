// app/test/launcher/bootstrap_payload_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/local_agent_launcher.dart';
import 'package:antgrid/services/keychain_device_store.dart';

void main() {
  group('BootstrapPayload.toJsonLine', () {
    test('local-only payload has firstProject and no machine block', () {
      final p = BootstrapPayload(projectId: 'p1', projectPath: '/tmp/p1');
      final j = jsonDecode(p.toJsonLine().trim()) as Map<String, dynamic>;
      expect(j.containsKey('machine'), isFalse);
      expect(j['firstProject'], {
        'projectId': 'p1',
        'projectPath': '/tmp/p1',
        'mode': 'local',
      });
    });

    test('with a device record, machine block carries auth + endpoints', () {
      final device = DeviceRecord(
        userId: 'u-1', // required by DeviceRecord; NOT part of machine.auth
        deviceUuid: 'uuid-1',
        clientId: 'cid',
        clientSecret: 'csec',
        ed25519Pub: 'e-pub',
        ed25519Priv: 'e-priv',
        x25519Pub: 'x-pub',
        x25519Priv: 'x-priv',
      );
      final p = BootstrapPayload(
        projectId: 'p1',
        projectPath: '/tmp/p1',
        device: device,
        licenseApiUrl: 'http://localhost:8787',
        relayUrl: 'wss://relay.example',
      );
      final j = jsonDecode(p.toJsonLine().trim()) as Map<String, dynamic>;
      // firstProject is still local — desktop never opens a remote core in unit 3.
      expect(j['firstProject']['mode'], 'local');
      final m = j['machine'] as Map<String, dynamic>;
      expect(m['relayUrl'], 'wss://relay.example');
      expect(m['licenseApiUrl'], 'http://localhost:8787');
      expect(m['auth']['clientId'], 'cid');
      expect(m['auth']['deviceUuid'], 'uuid-1');
      expect(m['auth']['ed25519Priv'], 'e-priv');
      // Regression: userId must never leak into machine.auth (the bridge
      // AuthFields schema has no userId field).
      expect((m['auth'] as Map).containsKey('userId'), isFalse);
    });

    test(
      'machine-only payload omits firstProject and carries the machine block',
      () {
        final device = DeviceRecord(
          userId: 'u-1',
          deviceUuid: 'uuid-1',
          clientId: 'cid',
          clientSecret: 'csec',
          ed25519Pub: 'e-pub',
          ed25519Priv: 'e-priv',
          x25519Pub: 'x-pub',
          x25519Priv: 'x-priv',
        );
        final p = BootstrapPayload.machineOnly(
          device: device,
          licenseApiUrl: 'http://localhost:8787',
          relayUrl: 'wss://relay.example',
          ownerPid: 4242,
        );
        final j = jsonDecode(p.toJsonLine().trim()) as Map<String, dynamic>;
        expect(j.containsKey('firstProject'), isFalse);
        expect(j['ownerPid'], 4242);
        expect(j['machine']['auth']['deviceUuid'], 'uuid-1');
        expect(j['machine']['relayUrl'], 'wss://relay.example');
      },
    );

    test(
      'machine-only payload with no device omits both firstProject and machine',
      () {
        final p = BootstrapPayload.machineOnly(ownerPid: 7);
        final j = jsonDecode(p.toJsonLine().trim()) as Map<String, dynamic>;
        expect(j.containsKey('firstProject'), isFalse);
        expect(j.containsKey('machine'), isFalse);
        expect(j['ownerPid'], 7);
      },
    );
  });
}
