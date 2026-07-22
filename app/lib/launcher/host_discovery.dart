// app/lib/launcher/host_discovery.dart
import 'dart:convert';
import 'dart:io';

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

String _homeDir() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    '';

/// The Antgrid home directory. Mirrors the bridge's `resolveAbDir()`:
/// `ANTGRID_DIR` if set, else `~/.antgrid`. [abDir] overrides for tests.
String hostDir({String? abDir}) =>
    abDir ?? Platform.environment['ANTGRID_DIR'] ?? '${_homeDir()}/.antgrid';

String hostFilePath({String? abDir}) => '${hostDir(abDir: abDir)}/host.json';

Future<HostFile?> readHostFile(String path) async {
  final f = File(path);
  if (!await f.exists()) return null;
  return HostFile.tryParse(await f.readAsString());
}
