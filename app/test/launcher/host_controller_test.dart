// app/test/launcher/host_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/host_discovery.dart';

HostFile _host({int pid = 100, int port = 6000, String token = 'tok'}) =>
    HostFile(
      version: 1,
      pid: pid,
      controlPort: port,
      token: token,
      startedAt: 's',
      agentVersion: 'v',
    );

void main() {
  test('trusts a live host (alive PID + successful ping); no spawn', () async {
    var spawns = 0;
    final c = HostController(
      readHost: () async => _host(),
      pidAlive: (pid) async => true,
      ping: (h) async => true,
      devMode: () => false,
      spawnHost: () async {
        spawns++;
        return _host();
      },
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 6000);
    expect(spawns, 0);
  });

  test('respawns when host.json is absent', () async {
    var spawns = 0;
    final c = HostController(
      readHost: () async => null,
      pidAlive: (pid) async => true,
      ping: (h) async => true,
      spawnHost: () async {
        spawns++;
        return _host(pid: 999, port: 7000);
      },
    );
    final h = await c.ensureHost();
    expect(h.pid, 999);
    expect(spawns, 1);
  });

  test('respawns when the PID is dead', () async {
    var spawns = 0;
    final c = HostController(
      readHost: () async => _host(pid: 1),
      pidAlive: (pid) async => false,
      ping: (h) async => false, // dead PID → control plane unreachable
      spawnHost: () async {
        spawns++;
        return _host(port: 7777);
      },
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 7777);
    expect(spawns, 1);
  });

  test('reaps an alive-but-unhealthy host before respawning (no zombie)',
      () async {
    var spawns = 0;
    final terminated = <int>[];
    final c = HostController(
      readHost: () async => _host(pid: 100),
      pidAlive: (pid) async => true,
      ping: (h) async => false, // PID alive but control plane unreachable
      devMode: () => false,
      terminate: (pid) async => terminated.add(pid),
      spawnHost: () async {
        spawns++;
        return _host(port: 8888);
      },
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 8888);
    expect(spawns, 1);
    // The unhealthy host's PID must be terminated before the fresh spawn.
    expect(terminated, [100]);
  });

  test('dev mode respawns a healthy prior-run host (stale bridge code)',
      () async {
    var spawns = 0;
    final terminated = <int>[];
    final c = HostController(
      readHost: () async => _host(pid: 100),
      pidAlive: (pid) async => true,
      ping: (h) async => true, // healthy — but dev wants fresh code
      devMode: () => true,
      bridgeStale: (_) => true, // edited bridge code since host start
      terminate: (pid) async => terminated.add(pid),
      spawnHost: () async {
        spawns++;
        return _host(port: 8500);
      },
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 8500);
    expect(spawns, 1);
    expect(terminated, [100]); // prior-run host killed for fresh code
  });

  test('dev mode attaches to a warm host when bridge code is unchanged',
      () async {
    var spawns = 0;
    final terminated = <int>[];
    final c = HostController(
      readHost: () async => _host(pid: 100, port: 6000),
      pidAlive: (pid) async => true,
      ping: (h) async => true, // healthy prior-run host
      devMode: () => true,
      bridgeStale: (_) => false, // nothing changed since host start
      terminate: (pid) async => terminated.add(pid),
      spawnHost: () async {
        spawns++;
        return _host(port: 8500);
      },
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 6000); // attached to the warm host, not a respawn
    expect(spawns, 0);
    expect(terminated, isEmpty);
  });

  test('reuses a host verified within the TTL without re-probing', () async {
    var reads = 0;
    var pings = 0;
    final c = HostController(
      readHost: () async {
        reads++;
        return _host();
      },
      pidAlive: (pid) async => true,
      ping: (h) async {
        // The control ping is the liveness probe on the healthy-attach path
        // (ping-first); pidAlive isn't reached unless the ping fails.
        pings++;
        return true;
      },
      devMode: () => false,
      now: () => DateTime(2026), // frozen clock → always within TTL
      spawnHost: () async => _host(),
    );
    await c.ensureHost();
    await c.ensureHost();
    await c.ensureHost();
    // Only the first call probes; the rest hit the verified-host cache.
    expect(reads, 1);
    expect(pings, 1);
  });

  test('single-flight: concurrent cold starts spawn exactly one host', () async {
    var spawns = 0;
    final c = HostController(
      readHost: () async => null,
      pidAlive: (pid) async => true,
      ping: (h) async => true,
      devMode: () => false,
      spawnHost: () async {
        spawns++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _host(port: 9100);
      },
    );
    final results = await Future.wait([c.ensureHost(), c.ensureHost(), c.ensureHost()]);
    expect(spawns, 1);
    expect(results.every((h) => h.controlPort == 9100), isTrue);
  });

  test(
      'default dev-mode (no override) respawns a healthy prior-run host in a '
      'non-release build, even without ANTGRID_AGENT_PREARGS', () async {
    // Regression: the debug repo-bridge-via-bun fallback sets no
    // ANTGRID_AGENT_PREARGS, so dev-mode must key on kReleaseMode (false under
    // `flutter test`) — otherwise the app attaches to a host running stale
    // bridge code after an edit + relaunch.
    var spawns = 0;
    final terminated = <int>[];
    final c = HostController(
      readHost: () async => _host(pid: 100),
      pidAlive: (pid) async => true,
      ping: (h) async => true, // healthy prior-run host
      // devMode intentionally NOT injected → exercises _defaultDevMode().
      bridgeStale: (_) => true, // isolate the devMode-detection assertion
      terminate: (pid) async => terminated.add(pid),
      spawnHost: () async {
        spawns++;
        return _host(port: 8600);
      },
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 8600);
    expect(spawns, 1);
    expect(terminated, [100]);
  });

  group('resolveHostCommand', () {
    HostCommand resolve({
      Map<String, String> env = const {},
      String exeDir = r'C:\app\build\windows\x64\runner\Debug',
      Set<String> present = const {},
      String? bridgeEntry,
      String bun = r'C:\Users\me\.bun\bin\bun.exe',
      bool isWindows = true,
      bool isRelease = false,
    }) =>
        resolveHostCommand(
          env: env,
          exeDir: exeDir,
          exists: present.contains,
          findBridgeEntry: () => bridgeEntry,
          resolveBun: () => bun,
          isWindows: isWindows,
          isRelease: isRelease,
        );

    test('ANTGRID_AGENT_BIN wins when it exists (no preargs)', () {
      final cmd = resolve(
        env: {'ANTGRID_AGENT_BIN': r'C:\bun.exe'},
        present: {r'C:\bun.exe'},
      );
      expect(cmd.binary, r'C:\bun.exe');
      expect(cmd.preargs, isEmpty);
    });

    test('falls through a stale ANTGRID_AGENT_BIN to the bundled sibling', () {
      // The resolver joins with `/` onto exeDir (see resolveHostCommand).
      const bundled = r'C:\app\build\windows\x64\runner\Debug/antgrid-bridge.exe';
      final cmd = resolve(
        env: {'ANTGRID_AGENT_BIN': r'C:\gone.exe'}, // set but absent
        present: {bundled},
      );
      expect(cmd.binary, bundled);
      expect(cmd.preargs, isEmpty);
    });

    test('debug build runs the repo bridge entry via bun', () {
      const entry = r'C:\repo\bridge\src\index.ts';
      final cmd = resolve(bridgeEntry: entry, isRelease: false);
      expect(cmd.binary, r'C:\Users\me\.bun\bin\bun.exe');
      expect(cmd.preargs, [entry]);
    });

    test(
        'REGRESSION: Windows refuses the bare "antgrid" fallback (would '
        'self-spawn the app)', () {
      // No env, no bundled sibling, no repo entry found (e.g. installed app or
      // IDE launch where the walk fails) → must throw, never return "antgrid".
      expect(
        () => resolve(bridgeEntry: null, isRelease: true),
        throwsA(isA<StateError>()),
      );
    });

    test('non-Windows keeps the bare "antgrid" PATH fallback', () {
      final cmd = resolve(bridgeEntry: null, isRelease: true, isWindows: false);
      expect(cmd.binary, 'antgrid');
      expect(cmd.preargs, isEmpty);
    });
  });
}
