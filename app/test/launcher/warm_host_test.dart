// app/test/launcher/warm_host_test.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/host_discovery.dart';
import 'package:antgrid/launcher/local_agent_launcher.dart';
import 'package:antgrid/services/keychain_device_store.dart';

HostFile _host({int pid = 100, int port = 6000}) => HostFile(
  version: 1,
  pid: pid,
  controlPort: port,
  token: 'tok',
  startedAt: 's',
  agentVersion: 'v',
);

void main() {
  test('warmHost sets a machine-only bootstrap and spawns the host', () async {
    var spawns = 0;
    final controller = HostController(
      readHost: () async => null, // no host yet → ensureHost spawns
      ping: (h) async => true,
      spawnHost: () async {
        spawns++;
        return _host();
      },
    );
    final launcher = LocalAgentLauncher(host: controller);

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

    await launcher.warmHost(
      device: device,
      licenseApiUrl: 'http://localhost:8787',
      relayUrl: 'wss://relay.example',
    );

    expect(spawns, 1);
    // The builder set on the controller must be project-less and carry the machine block.
    final payload = controller.bootstrapBuilder!();
    final j = jsonDecode(payload.toJsonLine().trim()) as Map<String, dynamic>;
    expect(j.containsKey('firstProject'), isFalse);
    expect(j['machine']['auth']['deviceUuid'], 'uuid-1');
  });

  test(
    'warmHost with no device spawns a machine-less (local-only) host',
    () async {
      var spawns = 0;
      final controller = HostController(
        readHost: () async => null,
        ping: (h) async => true,
        spawnHost: () async {
          spawns++;
          return _host();
        },
      );
      final launcher = LocalAgentLauncher(host: controller);

      await launcher.warmHost();

      expect(spawns, 1);
      final j =
          jsonDecode(controller.bootstrapBuilder!().toJsonLine().trim())
              as Map<String, dynamic>;
      expect(j.containsKey('firstProject'), isFalse);
      expect(j.containsKey('machine'), isFalse);
    },
  );

  test(
    'forceRespawn re-arms the builder even when one was already set',
    () async {
      var spawns = 0;
      final controller = HostController(
        readHost: () async =>
            null, // ownedHostPid stays null → shutdownOwnedHost no-ops
        ping: (h) async => true,
        spawnHost: () async {
          spawns++;
          return _host();
        },
      );
      final launcher = LocalAgentLauncher(host: controller);

      await launcher.warmHost(); // machine-less first
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
      await launcher.warmHost(
        device: device,
        licenseApiUrl: 'http://localhost:8787',
        relayUrl: 'wss://relay.example',
        forceRespawn: true,
      );

      final j =
          jsonDecode(controller.bootstrapBuilder!().toJsonLine().trim())
              as Map<String, dynamic>;
      expect(j['machine']['auth']['deviceUuid'], 'uuid-1');
      expect(spawns, 2);
    },
  );

  test('forceRespawn drains an in-flight spawn instead of joining it', () async {
    var spawns = 0;
    final firstSpawnGate = Completer<void>();
    final controller = HostController(
      readHost: () async => null,
      ping: (h) async => true,
      spawnHost: () async {
        spawns++;
        // Hold the first (machine-less) spawn open so a forceRespawn arrives
        // while it is still in flight.
        if (spawns == 1) await firstSpawnGate.future;
        return _host(pid: 100 + spawns);
      },
    );
    final launcher = LocalAgentLauncher(host: controller);

    // Kick the initial machine-less warm-up but don't await — its spawn parks.
    final first = launcher.warmHost();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(spawns, 1);

    // A device-bearing force-respawn must NOT be joined to the in-flight spawn
    // (which carries the OLD machine-less bootstrap); it drains it, then spawns.
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
    final respawn = launcher.warmHost(
      device: device,
      licenseApiUrl: 'http://localhost:8787',
      relayUrl: 'wss://relay.example',
      forceRespawn: true,
    );

    firstSpawnGate.complete(); // release the parked first spawn
    await Future.wait([first, respawn]);

    // Two distinct spawns — the respawn started fresh rather than returning the
    // first spawn's future — and the device-bearing builder won.
    expect(spawns, 2);
    final j =
        jsonDecode(controller.bootstrapBuilder!().toJsonLine().trim())
            as Map<String, dynamic>;
    expect(j['machine']['auth']['deviceUuid'], 'uuid-1');
  });
}
