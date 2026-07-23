// app/lib/launcher/host_discovery.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;

import '../config/storage_scope.dart' show storageScopeOverride;

/// In-memory shape of `~/.antgrid/host.json`.
/// Mirror of `bridge/src/host-discovery.ts` `HostFileSchema`.
class HostFile {
  final int version;
  final int pid;
  final int controlPort;
  final String token;
  final String startedAt;
  final String agentVersion;

  HostFile({
    required this.version,
    required this.pid,
    required this.controlPort,
    required this.token,
    required this.startedAt,
    required this.agentVersion,
  });

  /// Returns null on missing fields, wrong version, or any parse error.
  static HostFile? tryParse(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      if (m['version'] != 1) return null;
      final port = m['controlPort'];
      if (port is! int || port < 1 || port > 65535) return null;
      return HostFile(
        version: m['version'] as int,
        pid: m['pid'] as int,
        controlPort: port,
        token: m['token'] as String,
        startedAt: m['startedAt'] as String,
        agentVersion: m['agentVersion'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

// USERPROFILE first: matches Node's os.homedir() on Windows (what the bridge
// resolves on its own), so the two never disagree on a stray-HOME box
// (Git-Bash/MSYS2/corporate profiles sometimes set HOME on Windows too).
// Harmless elsewhere — USERPROFILE is unset on POSIX.
String _homeDir() =>
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';

/// The Antgrid home directory the app and its spawned host must agree on.
///
/// Precedence: explicit [abDir] (tests) → an `ANTGRID_DIR` already in the
/// environment (an explicit user/dev-launcher override, honored in every build
/// mode) → a build-mode default. Debug/profile builds default to
/// `~/.antgrid-dev` (plus a `-<scope>` suffix when `ANTGRID_STORAGE_SCOPE` is
/// set, keeping the host directory in sync with the app-storage scope from
/// `storage_scope.dart`) so a dev build never shares pairing, relay-epoch, or
/// device state with an installed release app pointed at `~/.antgrid`.
///
/// Mirrors the bridge's `resolveAbDir()`, but the bridge has no build-mode
/// notion — so the app is authoritative and passes the resolved value to the
/// host via ANTGRID_DIR on spawn (see host_controller.dart's spawnHostProcess).
String hostDir({String? abDir}) {
  if (abDir != null) return abDir;
  final env = Platform.environment['ANTGRID_DIR'];
  if (env != null && env.isNotEmpty) return env;
  if (kReleaseMode) return '${_homeDir()}/.antgrid';
  final suffix = storageScopeOverride.isNotEmpty
      ? '-$storageScopeOverride'
      : '';
  return '${_homeDir()}/.antgrid-dev$suffix';
}

String hostFilePath({String? abDir}) => '${hostDir(abDir: abDir)}/host.json';

Future<HostFile?> readHostFile(String path) async {
  final f = File(path);
  if (!await f.exists()) return null;
  return HostFile.tryParse(await f.readAsString());
}
