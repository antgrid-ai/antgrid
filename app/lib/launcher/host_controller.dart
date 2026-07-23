// app/lib/launcher/host_controller.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'discovery.dart' show isPidAlive, terminatePid, terminateTree;
import 'host_control_client.dart';
import 'host_discovery.dart';
import 'local_agent_launcher.dart' show BootstrapPayload, AgentEvent;

void _log(String msg) => debugPrint('[HostController] $msg');

/// Owns the singleton host process for this machine: discovery, liveness
/// verification, and single-flighted respawn. One per app process.
///
/// Seams are function-typed so the decision logic is unit-testable without a
/// real `bun`. The default constructor wires the real implementations.
class HostController {
  HostController({
    Future<HostFile?> Function()? readHost,
    Future<bool> Function(int pid)? pidAlive,
    Future<bool> Function(HostFile host)? ping,
    Future<HostFile> Function()? spawnHost,
    Future<void> Function(int pid)? terminate,
    DateTime Function()? now,
    bool Function()? devMode,
    bool Function(String startedAtIso)? bridgeStale,
  })  : _readHost = readHost ?? _defaultReadHost,
        _pidAlive = pidAlive ?? isPidAlive,
        _ping = ping ?? _defaultPing,
        _terminate = terminate ?? terminatePid,
        _now = now ?? DateTime.now,
        _devMode = devMode ?? _defaultDevMode,
        _bridgeStale = bridgeStale ?? _defaultBridgeStale,
        _spawnHost = spawnHost {
    // _spawnHost defaults to the real spawn only when not injected. We can't
    // reference an instance method in an initializer, so bind it here.
    _spawnHostFn = _spawnHost ?? _realSpawnHost;
  }

  final Future<HostFile?> Function() _readHost;
  final Future<bool> Function(int pid) _pidAlive;
  final Future<bool> Function(HostFile host) _ping;
  final Future<void> Function(int pid) _terminate;
  final DateTime Function() _now;
  final bool Function() _devMode;
  final bool Function(String startedAtIso) _bridgeStale;
  final Future<HostFile> Function()? _spawnHost;
  late final Future<HostFile> Function() _spawnHostFn;

  // Dev mode = we're running an UNBUNDLED bridge whose code can be stale across
  // a hot-restart (bun has no hot-reload), so a healthy prior-run host should be
  // terminated and respawned for fresh code. True for any non-release build
  // (debug/profile — including the repo-bridge-via-bun fallback in
  // resolveHostCommand, which sets no ANTGRID_AGENT_PREARGS), and also when a
  // dev launcher explicitly set ANTGRID_AGENT_PREARGS in a release build.
  static bool _defaultDevMode() =>
      !kReleaseMode ||
      (Platform.environment['ANTGRID_AGENT_PREARGS']?.isNotEmpty ?? false);

  /// True when `<repo>/bridge/src` changed since the running host started, so a
  /// respawn is needed to pick up edits. Conservative: true on any uncertainty
  /// so we never silently run stale bridge code. Scope is bridge/src only —
  /// after editing a sibling TS workspace, restart the app manually.
  static bool _defaultBridgeStale(String startedAtIso) {
    try {
      final started = DateTime.tryParse(startedAtIso);
      if (started == null) return true;
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final entry = _findRepoBridgeEntry(exeDir); // <repo>/bridge/src/index.ts
      if (entry == null) return true; // bundled/installed build — shouldn't reach here
      final srcDir = File(entry).parent; // <repo>/bridge/src
      for (final f in srcDir.listSync(recursive: true, followLinks: false)) {
        if (f is! File) continue;
        if (f.statSync().modified.isAfter(started)) return true;
      }
      return false;
    } catch (_) {
      return true; // any FS/parse error → respawn rather than risk stale code
    }
  }

  /// Cache of the last host verified live + when it was verified. Lets rapid
  /// project switches skip the disk-read + PID probe + control ping when the
  /// host was just confirmed (the PID probe shells out to `tasklist` on Windows,
  /// ~100-200ms). Bounded by [_verifyTtl]; dropped by [invalidate] on any
  /// control failure against the cached host.
  HostFile? _verified;
  DateTime? _verifiedAt;
  static const _verifyTtl = Duration(seconds: 3);

  /// Builds the stdin bootstrap for a fresh host spawn. The launcher assigns it
  /// (it knows the first project + optional device record) before the first
  /// spawn — `openProject` with `??=` (first project to open wins), `warmHost`
  /// with `=` (a device-bearing warm-up overwrites a machine-less one). Mutable
  /// (not final / not a ctor param) so the launcher can assign it after
  /// constructing the shared host. Required for real spawns; unused when
  /// [spawnHost] is injected in tests.
  BootstrapPayload Function()? bootstrapBuilder;

  /// PID of a host THIS app spawned (for owned-teardown on quit). Null when we
  /// attached to a host left running by a prior app run.
  int? ownedHostPid;

  /// Broadcast of structured events parsed from the host's stderr JSON lines
  /// (e.g. `auth_revoked`). Empty stream until/unless this app spawns a host.
  Stream<AgentEvent> get hostEvents => _events.stream;
  final _events = StreamController<AgentEvent>.broadcast();

  Future<HostFile>? _inFlight;
  Process? _proc;

  static Future<HostFile?> _defaultReadHost() => readHostFile(hostFilePath());

  static Future<bool> _defaultPing(HostFile host) async {
    final client = HostControlClient(port: host.controlPort, token: host.token);
    try {
      await client.projectList();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Resolve a live host, respawning if stale. Single-flighted: concurrent
  /// cold-start callers share one spawn.
  Future<HostFile> ensureHost() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final fut = _ensureHostInner();
    _inFlight = fut;
    return fut.whenComplete(() => _inFlight = null);
  }

  /// Resolve the live host ONLY if one is already running — NEVER spawns. Returns
  /// null when there's no host.json or the discovered host doesn't answer the
  /// liveness ping. For best-effort fire-and-forget verbs (e.g. project:forget on
  /// delete) that must not pay a cold host spawn just to reach the bridge.
  Future<HostFile?> peekHost() async {
    final disc = await _readHost();
    if (disc == null) return null;
    if (!await _ping(disc)) return null;
    return disc;
  }

  /// Drop the verified-host cache so the next [ensureHost] re-probes (and
  /// respawns if needed). Call after a control/transport failure against the
  /// host this controller last handed out.
  void invalidate() {
    _verified = null;
    _verifiedAt = null;
  }

  /// Await any spawn already in flight (swallowing its outcome) so a caller that
  /// must spawn FRESH — `warmHost(forceRespawn: true)` — doesn't get joined to it
  /// by [ensureHost]'s single-flight and silently inherit its bootstrap. After
  /// this returns, `_inFlight` is null, so the next [ensureHost] starts anew.
  Future<void> drainInFlight() async {
    final pending = _inFlight;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      // A failed in-flight spawn is the forced-respawn caller's cue to retry,
      // not an error to propagate.
    }
  }

  /// Tear down the host THIS app spawned, on app close, so the machine-level
  /// daemon doesn't outlive the app. No-op when we merely attached to a host a
  /// prior run left running (`ownedHostPid == null`) — per the owned-only
  /// teardown policy — or when the live host is no longer the one we own.
  ///
  /// Sends a graceful `host:shutdown` (the host flushes state + kills its PTYs
  /// via the same path as SIGTERM), waits briefly for the process to exit, then
  /// force-kills the whole tree as a backstop if it overstays. Best-effort: a
  /// failure here must never block app exit.
  Future<void> shutdownOwnedHost() async {
    final owned = ownedHostPid;
    if (owned == null) return;

    HostFile? disc;
    try {
      disc = await _readHost();
    } catch (_) {
      disc = null;
    }
    // Only act if the running host IS the one we own (pid match) — never kill a
    // host another run spawned, even if discovery now points at it.
    if (disc != null && disc.pid == owned) {
      final client = HostControlClient(port: disc.controlPort, token: disc.token);
      try {
        await client.hostShutdown().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Wedged or already gone — fall through to the force backstop.
      } finally {
        client.close();
      }
    }

    // Wait up to ~3s for graceful exit; force-kill the tree if it overstays
    // (a /T kill reaps the host's PTY grandchildren too).
    final deadline = _now().add(const Duration(seconds: 3));
    while (_now().isBefore(deadline)) {
      if (!await isPidAlive(owned)) {
        ownedHostPid = null;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await terminateTree(owned);
    ownedHostPid = null;
  }

  HostFile _markVerified(HostFile h) {
    _verified = h;
    _verifiedAt = _now();
    return h;
  }

  Future<HostFile> _ensureHostInner() async {
    // Trust a host verified within the TTL without re-probing disk/PID/port.
    final cached = _verified;
    final at = _verifiedAt;
    if (cached != null && at != null && _now().difference(at) < _verifyTtl) {
      return cached;
    }

    final disc = await _readHost();
    if (disc != null) {
      // Ping first: a token-authenticated answer proves the host is alive AND
      // ours (the token gates `/control`), so we attach without the ~50-200ms
      // Windows `tasklist` probe — which now runs only on the ping-fail path.
      if (await _ping(disc)) {
        // Dev mode respawns a prior-run host to pick up bridge edits (bun has no
        // hot-reload), but only when bridge/src actually changed — an
        // unconditional respawn cost ~1s bun boot + a starved readiness poll on
        // every launch. `ownedHostPid == null` avoids churning a host we just
        // spawned during in-session project switches.
        if (_devMode() && ownedHostPid == null && _bridgeStale(disc.startedAt)) {
          _log('dev mode: bridge changed since host start — '
              'terminating pid=${disc.pid} for fresh code');
          await _terminate(disc.pid);
          return _markVerified(await _spawnHostFn());
        }
        _log('attached to running host pid=${disc.pid} port=${disc.controlPort}');
        return _markVerified(disc);
      }
      // Ping failed: probe the PID to tell a wedged host (alive → reap before
      // respawn) from a stale dead one.
      if (await _pidAlive(disc.pid)) {
        _log('unhealthy host pid=${disc.pid}; terminating before respawn');
        await _terminate(disc.pid);
      } else {
        _log('stale host (dead pid=${disc.pid}); respawning');
      }
    } else {
      _log('no host.json; spawning host');
    }
    return _markVerified(await _spawnHostFn());
  }

  /// Real spawn: start the bridge binary, write the bootstrap to stdin, then
  /// wait for host.json to appear AND the control listener to answer.
  Future<HostFile> _realSpawnHost() async {
    final builder = bootstrapBuilder;
    if (builder == null) {
      throw StateError('HostController: bootstrapBuilder is required to spawn');
    }
    final payload = builder();
    final proc = await spawnHostProcess(payload);
    _proc = proc;
    ownedHostPid = proc.pid;

    // Event-driven readiness: the host logs "host.json written" on stdout the
    // instant its control plane binds. Waking the poll below on that line skips
    // a delay tick — which matters during cold-start, when main-isolate
    // saturation can balloon a nominal 100ms `Future.delayed` to ~2s.
    final hostAnnouncedReady = Completer<void>();
    void signalReady() {
      if (!hostAnnouncedReady.isCompleted) hostAnnouncedReady.complete();
    }

    // Surfaces stderr structured events (auth_revoked) and the stdout ready marker.
    _tailHostStderr(proc, onHostReady: signalReady);

    // Local flag scoped to THIS spawn so a prior exit never poisons a retry.
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));

    const intervalMs = 100;
    final spawnedAt = _now();
    // Wall-clock ceiling, not an iteration count — each poll awaits a ping
    // bounded at ≤2s, so counting iterations could overshoot. 30s leaves
    // headroom for a cold bun (8-12s on Windows).
    final deadline = spawnedAt.add(const Duration(seconds: 30));
    while (_now().isBefore(deadline)) {
      if (exited) break;
      final h = await readHostFile(hostFilePath());
      if (h != null && await _ping(h)) {
        _log('host ready after '
            '${_now().difference(spawnedAt).inMilliseconds}ms (port ${h.controlPort})');
        return h;
      }
      // Wake on the ready announcement or the interval, whichever is first. Once
      // announced the completer stays resolved, so racing it would busy-spin —
      // fall back to a plain throttled tick.
      if (hostAnnouncedReady.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: intervalMs));
      } else {
        await Future.any([
          hostAnnouncedReady.future,
          Future<void>.delayed(const Duration(milliseconds: intervalMs)),
        ]);
      }
    }
    try {
      proc.kill();
    } catch (_) {}
    throw StateError(
      'host failed to start (no live control plane after 30s). '
      'See host.log in ${hostDir()} for details.',
    );
  }

  void _tailHostStderr(Process proc, {void Function()? onHostReady}) {
    // Open the host log file for tee-ing both stdout and stderr.
    final dir = Directory(hostDir());
    dir.createSync(recursive: true);
    final logPath = '${hostDir()}/host.log';
    final logSink = File(logPath).openWrite(mode: FileMode.append);
    logSink.writeln(
      '--- ${DateTime.now().toIso8601String()} host spawned pid=${proc.pid} ---',
    );

    // Per-stream UTF-8 decoders. Host log strings may contain em-dashes / arrows
    // / box-drawing chars; `allowMalformed: true` tolerates multi-byte chars
    // split across chunk boundaries.
    final stdoutDecoder = const Utf8Decoder(allowMalformed: true);
    final stderrDecoder = const Utf8Decoder(allowMalformed: true);

    var pendingDrains = 2;
    void onStreamDone() {
      if (--pendingDrains == 0) logSink.close();
    }

    void tee(String tag, List<int> chunk, Utf8Decoder decoder) {
      logSink.add(chunk);
      if (kDebugMode) {
        try {
          debugPrint('[host $tag] ${decoder.convert(chunk).trimRight()}');
        } catch (_) {}
      }
    }

    // Partial line buffer for stderr — chunks may not align to newlines.
    final stderrLineBuf = StringBuffer();

    // Partial line buffer for stdout — scanned for the ready marker. Fires
    // onHostReady at most once; the spawn poll re-verifies anyway.
    final stdoutLineBuf = StringBuffer();
    var firedReady = false;
    void scanStdoutForReady(List<int> chunk) {
      if (firedReady || onHostReady == null) return;
      stdoutLineBuf.write(stdoutDecoder.convert(chunk));
      final full = stdoutLineBuf.toString();
      // Key on "host.json written" (not "control plane ready", logged on the
      // same line) so the file is guaranteed on disk when we react.
      if (full.contains('host.json written')) {
        firedReady = true;
        stdoutLineBuf.clear();
        onHostReady();
        return;
      }
      final nl = full.lastIndexOf('\n');
      if (nl >= 0) {
        final tail = full.substring(nl + 1);
        stdoutLineBuf
          ..clear()
          ..write(tail);
      }
    }

    void parseStderrChunk(List<int> chunk) {
      final text = stderrDecoder.convert(chunk);
      stderrLineBuf.write(text);
      final full = stderrLineBuf.toString();
      final lines = full.split('\n');
      // Last element may be incomplete; keep it in the buffer.
      stderrLineBuf
        ..clear()
        ..write(lines.last);
      for (var i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        // Attempt JSON parse; silently ignore non-JSON lines.
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            final event = decoded['event'];
            if (event is String) {
              _events.add(AgentEvent(event, decoded));
            }
          }
        } catch (_) {
          // Not JSON — normal log line, already tee'd above.
        }
      }
    }

    proc.stdout.listen(
      (chunk) {
        tee('stdout', chunk, stdoutDecoder);
        scanStdoutForReady(chunk);
      },
      onDone: onStreamDone,
      onError: (e) => _log('stdout error: $e'),
    );
    proc.stderr.listen(
      (chunk) {
        tee('stderr', chunk, stderrDecoder);
        parseStderrChunk(chunk);
      },
      onDone: () {
        // Flush any remaining partial line before closing the controller.
        final remaining = stderrLineBuf.toString().trim();
        if (remaining.isNotEmpty) {
          try {
            final decoded = jsonDecode(remaining);
            if (decoded is Map<String, dynamic>) {
              final event = decoded['event'];
              if (event is String) {
                _events.add(AgentEvent(event, decoded));
              }
            }
          } catch (_) {}
        }
        // Do NOT close _events here. This controller (and its stream) outlives
        // any single host process — a respawn re-tails into the SAME stream.
        // Closing on first host exit would make a later spawn's _events.add
        // throw and permanently kill auth_revoked delivery. Closed only in
        // shutdown().
        onStreamDone();
      },
      onError: (e) => _log('stderr error: $e'),
    );
    _log('host log: $logPath');
  }

  Future<void> shutdown() async {
    try {
      _proc?.kill();
    } catch (_) {}
    await _events.close();
  }
}

/// A resolved host launch command: the executable plus any leading args (e.g.
/// the bridge entry script when we invoke `bun` directly in a dev build).
typedef HostCommand = ({String binary, List<String> preargs});

/// Pure resolution of the host launch command, factored out of [Platform] so it
/// is unit-testable. Priority:
///   1. `ANTGRID_AGENT_BIN` env var (dev launchers — paired with the
///      `ANTGRID_AGENT_PREARGS` script; see scripts/dev.ts / aspire).
///   2. Bundled `antgrid-bridge[.exe]` next to the app (release builds).
///   3. Debug/profile only: the repo's `bridge/src/index.ts` run via `bun`
///      (lets a bare `flutter run` / IDE launch work with no env setup).
///   4. `antgrid` on PATH (installed CLI).
///
/// Step 4 is REFUSED on Windows: the app executable is itself `antgrid.exe`,
/// and CreateProcess searches the calling process's own directory before PATH,
/// so a bare `antgrid` resolves back to the app — the launcher would spawn a
/// second copy of itself as the "host", which writes no host.json and the
/// caller times out after 30s. Fail loudly with guidance instead.
@visibleForTesting
HostCommand resolveHostCommand({
  required Map<String, String> env,
  required String exeDir,
  required bool Function(String path) exists,
  required String? Function() findBridgeEntry,
  required String Function() resolveBun,
  required bool isWindows,
  required bool isRelease,
}) {
  final binEnv = env['ANTGRID_AGENT_BIN'];
  if (binEnv != null && exists(binEnv)) {
    return (binary: binEnv, preargs: const <String>[]);
  }

  final bundled = isWindows ? '$exeDir/antgrid-bridge.exe' : '$exeDir/antgrid-bridge';
  if (exists(bundled)) {
    return (binary: bundled, preargs: const <String>[]);
  }

  if (!isRelease) {
    final script = findBridgeEntry();
    if (script != null) {
      return (binary: resolveBun(), preargs: <String>[script]);
    }
  }

  if (isWindows) {
    throw StateError(
      'No host bridge binary found. Set ANTGRID_AGENT_BIN (dev launchers '
      '`npm run dev` / `npm run aspire` do this), or bundle antgrid-bridge.exe '
      'next to the app. Refusing the bare "antgrid" PATH fallback: it resolves '
      "to this app's own executable (antgrid.exe) and would spawn a second copy "
      'of the app as the host.',
    );
  }
  return (binary: 'antgrid', preargs: const <String>[]);
}

/// Real resolution: wires [resolveHostCommand] to [Platform].
HostCommand _resolveHostCommand() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final cmd = resolveHostCommand(
    env: Platform.environment,
    exeDir: exeDir,
    exists: (p) => File(p).existsSync(),
    findBridgeEntry: () => _findRepoBridgeEntry(exeDir),
    resolveBun: _resolveBun,
    isWindows: Platform.isWindows,
    isRelease: kReleaseMode,
  );
  debugPrint(
    '[HostController] host command: ${cmd.binary} ${cmd.preargs.join(" ")}',
  );
  return cmd;
}

/// Walk up from [startDir] (the build-output exe dir) to the repo root, looking
/// for `bridge/src/index.ts`. Bounded so an installed app (no repo above it)
/// fails fast. Returns the absolute script path, or null if not found.
String? _findRepoBridgeEntry(String startDir) {
  var dir = Directory(startDir);
  for (var i = 0; i < 10; i++) {
    final entry = '${dir.path}/bridge/src/index.ts';
    if (File(entry).existsSync()) return entry;
    final parent = dir.parent;
    if (parent.path == dir.path) break; // filesystem root
    dir = parent;
  }
  return null;
}

/// Resolve `bun`: prefer the default install (`~/.bun/bin`), else bare `bun` on
/// PATH. Safe to PATH-resolve — `bun` has no name collision with the app.
String _resolveBun() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null) {
    final p = Platform.isWindows ? '$home/.bun/bin/bun.exe' : '$home/.bun/bin/bun';
    if (File(p).existsSync()) return p;
  }
  return Platform.isWindows ? 'bun.exe' : 'bun';
}

/// Spawns the singleton host process: resolves the binary, starts the process
/// (with the SAME Windows .cmd/.bat runInShell branch and ANTGRID_AGENT_PREARGS
/// handling as the old _spawn()), writes the bootstrap JSON line to stdin, then
/// returns the [Process].
///
/// NOTE: No `workingDirectory` is set — the host is machine-level (not
/// per-project). stdout/stderr tee-ing and event parsing are handled by the
/// caller's `_tailHostStderr`.
Future<Process> spawnHostProcess(BootstrapPayload payload) async {
  final cmd = _resolveHostCommand();
  final binary = cmd.binary;

  // Pre-args (newline-separated) prefix the agent command line — used in dev to
  // invoke bun directly with the agent script, skipping the .cmd wrapper (and
  // its visible cmd.exe popup on Windows). Env PREARGS (set by dev launchers
  // alongside ANTGRID_AGENT_BIN) take precedence; otherwise use the resolved
  // command's own preargs (e.g. the bridge entry script when we fell back to
  // invoking `bun` directly in a debug build).
  final preargsEnv = Platform.environment['ANTGRID_AGENT_PREARGS'];
  final envPreargs = (preargsEnv == null || preargsEnv.isEmpty)
      ? const <String>[]
      : preargsEnv
            .split('\n')
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
  // No subcommand args — the host reads stdin to learn its mode.
  final args = <String>[...(envPreargs.isNotEmpty ? envPreargs : cmd.preargs)];

  // Pin the host to the SAME data dir the app resolved. The app is the
  // authority on ANTGRID_DIR because only it knows the build mode: a debug
  // build resolves `~/.antgrid-dev` so it never shares pairing/relay-epoch/
  // device state with an installed release app on `~/.antgrid`. The bridge's
  // resolveAbDir() has no build-mode notion, so we must hand it the value here
  // rather than letting the child fall back to its own default.
  final abDir = hostDir();

  // Only export in non-release: a release build's abDir already equals what
  // the host's own resolveAbDir() resolves unprompted, and the host's PTY
  // sessions spread their environment into every user shell — exporting it
  // unconditionally would let a dev stack later launched from an Antgrid
  // terminal inherit ~/.antgrid as an "explicit override" and silently
  // collide with the release install.
  final hostEnv = kReleaseMode
      ? const <String, String>{}
      : {'ANTGRID_DIR': abDir};

  debugPrint(
    '[HostController] spawning host: binary="$binary" args=$args abDir="$abDir"',
  );

  // .cmd/.bat on Windows requires runInShell. Direct .exe invocation does
  // not — and avoiding the shell skips the visible cmd.exe popup window
  // that Windows would otherwise create for a GUI parent.
  final isWindowsScript =
      Platform.isWindows &&
      (binary.toLowerCase().endsWith('.cmd') ||
          binary.toLowerCase().endsWith('.bat'));

  late Process proc;
  try {
    proc = await Process.start(
      binary,
      args,
      // Merged onto the inherited env (includeParentEnvironment defaults true).
      environment: hostEnv,
      // `normal` mode lets us watch exitCode and stream stdio.
      mode: ProcessStartMode.normal,
      runInShell: isWindowsScript,
      // No workingDirectory — the host is machine-level, not per-project.
    );
  } catch (e, st) {
    debugPrint('[HostController] Process.start threw: $e\n$st');
    rethrow;
  }
  debugPrint(
    '[HostController] spawned host pid=${proc.pid}',
  );

  // Write the bootstrap line, then close stdin. The host reads exactly one
  // line and never expects more input.
  try {
    proc.stdin.write(payload.toJsonLine());
    await proc.stdin.flush();
    await proc.stdin.close();
  } catch (e) {
    debugPrint('[HostController] stdin write failed: $e');
    proc.kill();
    rethrow;
  }

  return proc;
}
