// app/test/launcher/host_controller_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/host_discovery.dart';
import 'package:antgrid/config/build_info.dart';

// ownerBuild is stamped with OUR build so the attach gate is satisfied; the
// tests that exercise the gate build a foreign or unstamped host themselves.
HostFile _host({
  int pid = 100,
  int port = 6000,
  String token = 'tok',
  String? ownerBuild,
}) => HostFile(
  version: 1,
  pid: pid,
  controlPort: port,
  token: token,
  startedAt: 's',
  agentVersion: 'v',
  ownerBuild: ownerBuild ?? BuildInfo.summary,
);

/// A host from before `ownerBuild` existed — no stamp at all.
HostFile _unstampedHost({int pid = 100, int port = 6000}) => HostFile(
  version: 1,
  pid: pid,
  controlPort: port,
  token: 'tok',
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

  test(
    'refuses a live host stamped with another build; reaps and respawns',
    () async {
      var spawns = 0;
      final terminated = <int>[];
      final treeKilled = <int>[];
      final c = HostController(
        // A host the previous install left running: pings fine, wrong build.
        readHost: () async => _host(pid: 100, ownerBuild: '1.0.0 (deadbee)'),
        pidAlive: (pid) async => true,
        ping: (h) async => true,
        devMode: () => false,
        terminate: (pid) async => terminated.add(pid),
        terminateTree: (pid) async => treeKilled.add(pid),
        spawnHost: () async {
          spawns++;
          return _host(pid: 222, port: 6001);
        },
      );
      final h = await c.ensureHost();
      expect(h.pid, 222);
      expect(spawns, 1);
      // Tree, not bare pid: the abandoned host's PTY children must die with it.
      expect(treeKilled, [100]);
      expect(terminated, isEmpty);
    },
  );

  test('refuses a live host carrying no build stamp at all', () async {
    var spawns = 0;
    final treeKilled = <int>[];
    final c = HostController(
      readHost: () async => _unstampedHost(pid: 101),
      pidAlive: (pid) async => true,
      ping: (h) async => true,
      devMode: () => false,
      terminateTree: (pid) async => treeKilled.add(pid),
      spawnHost: () async {
        spawns++;
        return _host(pid: 333);
      },
    );
    final h = await c.ensureHost();
    expect(h.pid, 333);
    expect(spawns, 1);
    expect(treeKilled, [101]);
  });

  test('reaps a foreign-stamped host at most once per run', () async {
    // Every release build resolves the same `~/.antgrid`, so two installs read
    // each other's stamp as foreign. Reaping on every ensureHost would make
    // each side kill the other's replacement in turn — every agent PTY dying
    // on each pass — until both exhaust their restart budget. One reap is all
    // the intent (replace a previous install's host) ever needs.
    var spawns = 0;
    final treeKilled = <int>[];
    var current = _host(pid: 100, ownerBuild: '1.0.0 (deadbee)');
    final c = HostController(
      readHost: () async => current,
      pidAlive: (pid) async => true,
      ping: (h) async => true,
      devMode: () => false,
      terminateTree: (pid) async => treeKilled.add(pid),
      spawnHost: () async {
        spawns++;
        // The rival app wins the respawn race and rewrites host.json with its
        // own stamp — what the readiness poll adopts, since it checks neither.
        current = _host(pid: 200, ownerBuild: '1.0.0 (deadbee)');
        return current;
      },
    );
    await c.ensureHost();
    expect(treeKilled, [100]);

    c.invalidate();
    final second = await c.ensureHost();
    expect(second.pid, 200, reason: 'attaches rather than reaping again');
    expect(spawns, 1);
    expect(treeKilled, [100]);
  });

  test('never reaps a host THIS run spawned, however it is stamped', () async {
    // A bridge binary too old to echo `ownerBuild` writes an unstamped
    // host.json. Reaping it would kill and respawn our own host every
    // _verifyTtl, forever — so the gate must exempt `ownedHostPid`.
    var spawns = 0;
    final treeKilled = <int>[];
    final c = HostController(
      readHost: () async => _unstampedHost(pid: 444),
      pidAlive: (pid) async => true,
      ping: (h) async => true,
      devMode: () => false,
      terminateTree: (pid) async => treeKilled.add(pid),
      spawnHost: () async {
        spawns++;
        return _unstampedHost(pid: 444);
      },
    )..ownedHostPid = 444;
    final h = await c.ensureHost();
    expect(h.pid, 444);
    expect(spawns, 0);
    expect(treeKilled, isEmpty);
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

  test(
    'reaps an alive-but-unhealthy host before respawning (no zombie)',
    () async {
      var spawns = 0;
      final terminated = <int>[];
      final treeKilled = <int>[];
      final c = HostController(
        readHost: () async => _host(pid: 100),
        pidAlive: (pid) async => true,
        ping: (h) async => false, // PID alive but control plane unreachable
        devMode: () => false,
        terminate: (pid) async => terminated.add(pid),
        terminateTree: (pid) async => treeKilled.add(pid),
        spawnHost: () async {
          spawns++;
          return _host(port: 8888);
        },
      );
      final h = await c.ensureHost();
      expect(h.controlPort, 8888);
      expect(spawns, 1);
      // Tree, not bare: a host that stopped answering its control plane can no
      // longer be told to stop its PTYs, so a `/F` without `/T` orphans them.
      expect(treeKilled, [100]);
      expect(terminated, isEmpty);
    },
  );

  test(
    'REGRESSION: a host that answers a LATER ping is never reaped',
    () async {
      // The bridge is one JS thread: a project open walks the file tree of the
      // repo AND every managed worktree, which stops it answering the control
      // plane for as long as the walk runs. Reaping on the first missed ping
      // killed a healthy host mid-open, and the respawn tore down the very
      // session the user was starting ("SessionsService disposed").
      var pings = 0;
      var spawns = 0;
      final treeKilled = <int>[];
      final c = HostController(
        readHost: () async => _host(pid: 100, port: 6000),
        pidAlive: (pid) async => true,
        ping: (h) async => ++pings > 2, // blocked for two attempts, then back
        devMode: () => false,
        terminateTree: (pid) async => treeKilled.add(pid),
        delay: (_) async {}, // no real grace sleep in tests
        spawnHost: () async {
          spawns++;
          return _host(port: 8888);
        },
      );
      final h = await c.ensureHost();
      expect(h.controlPort, 6000, reason: 'attached to the original host');
      expect(pings, 3);
      expect(spawns, 0);
      expect(treeKilled, isEmpty);
    },
  );

  test(
    'a host that misses every ping in the grace window is still reaped',
    () async {
      var pings = 0;
      var spawns = 0;
      final treeKilled = <int>[];
      final c = HostController(
        readHost: () async => _host(pid: 100),
        pidAlive: (pid) async => true,
        ping: (h) async {
          pings++;
          return false;
        },
        devMode: () => false,
        terminateTree: (pid) async => treeKilled.add(pid),
        delay: (_) async {},
        spawnHost: () async {
          spawns++;
          return _host(port: 8888);
        },
      );
      final h = await c.ensureHost();
      expect(h.controlPort, 8888);
      expect(spawns, 1);
      expect(treeKilled, [100]);
      // Bounded: the grace window must not turn into an unbounded retry loop.
      expect(pings, 3);
    },
  );

  test('a dead PID spends no grace window on retries', () async {
    var pings = 0;
    final c = HostController(
      readHost: () async => _host(pid: 1),
      pidAlive: (pid) async => false,
      ping: (h) async {
        pings++;
        return false;
      },
      delay: (_) async {},
      spawnHost: () async => _host(port: 7777),
    );
    final h = await c.ensureHost();
    expect(h.controlPort, 7777);
    // One ping, then the PID probe ends it — a corpse will never answer, and
    // waiting on it only delays the respawn that IS the recovery.
    expect(pings, 1);
  });

  test(
    'dev mode respawns a healthy prior-run host (stale bridge code)',
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
    },
  );

  test(
    'dev mode attaches to a warm host when bridge code is unchanged',
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
    },
  );

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

  test(
    'single-flight: concurrent cold starts spawn exactly one host',
    () async {
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
      final results = await Future.wait([
        c.ensureHost(),
        c.ensureHost(),
        c.ensureHost(),
      ]);
      expect(spawns, 1);
      expect(results.every((h) => h.controlPort == 9100), isTrue);
    },
  );

  test('default dev-mode (no override) respawns a healthy prior-run host in a '
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

  group('supervision', () {
    /// Drain the restart chain (delay → ensureHost → spawn), which spans
    /// several microtask hops.
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// A controller whose host is already "spawned" (generation 1) so
    /// [HostController.handleHostExit] can simulate the process dying.
    Future<HostController> spawned({
      required void Function() onSpawn,
      Future<HostFile> Function()? spawn,
      DateTime Function()? now,
      Future<void> Function(Duration d)? delay,
    }) async {
      final c = HostController(
        readHost: () async => null,
        pidAlive: (pid) async => false,
        ping: (h) async => true,
        devMode: () => false,
        now: now,
        delay: delay ?? (_) async {}, // no real backoff sleep in tests
        spawnHost:
            spawn ??
            () async {
              onSpawn();
              return _host(pid: 500);
            },
      );
      await c.ensureHost();
      c.ownedHostPid = 500;
      return c;
    }

    /// Drive [c] into [HostPhase.failed] by exhausting the crash-loop budget.
    /// Re-arms `ownedHostPid` after each exit because [HostController.handleHostExit]
    /// clears it.
    Future<void> driveToFailed(HostController c) async {
      for (var i = 0; i < 5; i++) {
        c.handleHostExit(generation: c.spawnGeneration, pid: 500, exitCode: 1);
        await settle();
        c.ownedHostPid = 500;
      }
    }

    test('respawns after an unexpected exit and reports the phases', () async {
      var spawns = 0;
      final c = await spawned(onSpawn: () => spawns++);
      expect(spawns, 1);
      expect(c.status.phase, HostPhase.up);

      final seen = <HostPhase>[];
      final sub = c.statusStream.listen((s) => seen.add(s.phase));

      c.handleHostExit(generation: 1, pid: 500, exitCode: 1);
      expect(c.status.phase, HostPhase.restarting);
      await settle();

      expect(spawns, 2, reason: 'the dead host was respawned');
      expect(c.status.phase, HostPhase.up);
      expect(seen, containsAllInOrder([HostPhase.restarting, HostPhase.up]));
      await sub.cancel();
    });

    test('an exit we caused is not respawned', () async {
      var spawns = 0;
      final c = await spawned(onSpawn: () => spawns++);
      await c.shutdownOwnedHost(); // marks the exit as expected
      c.handleHostExit(generation: 1, pid: 500, exitCode: 0);
      await settle();
      expect(spawns, 1, reason: 'teardown must not resurrect the host');
      expect(c.status.phase, HostPhase.stopped);
    });

    test('a stale generation exit is ignored', () async {
      var spawns = 0;
      final c = await spawned(onSpawn: () => spawns++);
      // Generation 0 = a process already replaced by the current one.
      c.handleHostExit(generation: 0, pid: 499, exitCode: 1);
      await settle();
      expect(spawns, 1);
      expect(c.status.phase, HostPhase.up);
      expect(c.ownedHostPid, 500, reason: 'the live host is untouched');
    });

    test('crash loop gives up after the budget and reports failed', () async {
      var spawns = 0;
      // Frozen clock → every exit lands inside the same restart window.
      final c = await spawned(
        onSpawn: () => spawns++,
        now: () => DateTime(2026),
      );
      await driveToFailed(c);
      // 1 initial + 3 supervised restarts, then the guard trips.
      expect(spawns, 4);
      expect(c.status.phase, HostPhase.failed);
      expect(c.status.detail, contains('Automatic restart is paused'));
    });

    test('retryNow clears the crash-loop budget and spawns again', () async {
      var spawns = 0;
      final c = await spawned(
        onSpawn: () => spawns++,
        now: () => DateTime(2026),
      );
      await driveToFailed(c);
      expect(c.status.phase, HostPhase.failed);

      await c.retryNow();
      expect(spawns, 5);
      expect(c.status.phase, HostPhase.up);
    });

    test('a late expected exit does not clobber a failed verdict', () async {
      var spawns = 0;
      final c = await spawned(
        onSpawn: () => spawns++,
        now: () => DateTime(2026),
      );
      await driveToFailed(c);
      expect(c.status.phase, HostPhase.failed);

      // Teardown marks the exit expected; the late exitCode callback must not
      // downgrade the failed verdict to stopped (that would hide the banner
      // and its retry affordance).
      await c.shutdownOwnedHost();
      c.handleHostExit(generation: c.spawnGeneration, pid: 500, exitCode: 1);
      await settle();
      expect(c.status.phase, HostPhase.failed);
    });

    test('teardown during the backoff cancels the pending restart', () async {
      var spawns = 0;
      final gate = Completer<void>();
      final c = await spawned(
        onSpawn: () => spawns++,
        delay: (_) => gate.future, // hold the restart in its backoff sleep
      );
      c.handleHostExit(generation: 1, pid: 500, exitCode: 1);
      expect(c.status.phase, HostPhase.restarting);

      // The crash already cleared ownedHostPid — teardown must STILL cancel
      // the sleeping restart, or quitting the app races a respawn to life.
      await c.shutdownOwnedHost();
      gate.complete();
      await settle();
      expect(spawns, 1, reason: 'the abandoned restart must not respawn');
    });

    test('a deliberate spawn after a recovered crash reports starting, '
        'not restarting', () async {
      var spawns = 0;
      final c = await spawned(
        onSpawn: () => spawns++,
        now: () => DateTime(2026),
      );
      c.handleHostExit(generation: 1, pid: 500, exitCode: 1);
      await settle();
      expect(c.status.phase, HostPhase.up);
      final recoveredGeneration = c.status.generation;

      // Ordinary spawn inside the 60s window (e.g. a forced respawn on
      // sign-in). The unpaid crash budget must not relabel it as a crash.
      final seen = <HostStatus>[];
      final sub = c.statusStream.listen(seen.add);
      c.invalidate();
      c.ownedHostPid = null;
      await c.ensureHost();
      await settle(); // flush queued stream deliveries before cancelling
      await sub.cancel();

      expect(seen.map((s) => s.phase), contains(HostPhase.starting));
      expect(seen.map((s) => s.phase), isNot(contains(HostPhase.restarting)));
      // And the new `up` carries a fresh generation, which is what tells the
      // rebind provider the process underneath the open sessions was replaced.
      expect(c.status.phase, HostPhase.up);
      expect(c.status.generation, greaterThan(recoveredGeneration));
    });

    test('a respawn that fails to start keeps retrying, then fails', () async {
      var spawns = 0;
      final c = await spawned(
        onSpawn: () => spawns++,
        now: () => DateTime(2026),
        spawn: () async {
          spawns++;
          if (spawns > 1) throw StateError('bun missing');
          return _host(pid: 500);
        },
      );
      c.handleHostExit(generation: 1, pid: 500, exitCode: 1);
      // Each failed spawn schedules the next until the budget is spent.
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(spawns, 4); // initial + 3 failed restart attempts
      expect(c.status.phase, HostPhase.failed);
    });
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
    }) => resolveHostCommand(
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
      const bundled =
          r'C:\app\build\windows\x64\runner\Debug/antgrid-bridge.exe';
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

    test('REGRESSION: Windows refuses the bare "antgrid" fallback (would '
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
