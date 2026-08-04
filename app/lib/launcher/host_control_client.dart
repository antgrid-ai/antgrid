// app/lib/launcher/host_control_client.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../services/control_plane_client.dart'
    show AgentWorkStatus, parseSessionStatuses;
import '../models/git_branch.dart';

/// Loopback data-plane connect info from a `project:open` response.
/// Non-null for all modes — every core binds a loopback listener. Mirror of
/// `control-protocol.ts` ConnectInfo.
class ConnectInfo {
  final int port;
  final String token;
  const ConnectInfo({required this.port, required this.token});
}

/// `project:open` / `project:start` response. Mirror of control-protocol.ts.
class OpenResult {
  final bool running;
  final ConnectInfo? connect;
  const OpenResult({required this.running, required this.connect});
}

/// Host-owned identity for a local folder. A linked worktree intentionally
/// resolves to its repository's primary checkout, so app-side path hashing can
/// never create a second project row for the same repository.
class ResolvedLocalProject {
  final String projectId;
  final String repoPath;
  final String selectedPath;
  final String label;
  final bool isGitRepository;
  const ResolvedLocalProject({
    required this.projectId,
    required this.repoPath,
    required this.selectedPath,
    required this.label,
    required this.isGitRepository,
  });

  factory ResolvedLocalProject.fromJson(Map<String, dynamic> json) {
    final projectId = json['projectId'];
    final repoPath = json['repoPath'];
    final selectedPath = json['selectedPath'];
    final label = json['label'];
    if (projectId is! String || repoPath is! String || selectedPath is! String || label is! String) {
      throw HostControlException('BAD_RESPONSE', 'malformed project:resolve response: $json');
    }
    return ResolvedLocalProject(
      projectId: projectId,
      repoPath: repoPath,
      selectedPath: selectedPath,
      label: label,
      isGitRepository: json['isGitRepository'] == true,
    );
  }
}

/// One catalog entry. Mirror of `control-protocol.ts` ProjectSummary.
class ProjectSummary {
  final String projectId;
  final String path;
  final bool running;
  final String mode; // "local" | "remote"
  /// Live work status for warm cores. Null until the first bus frame arrives.
  final String? workStatus;

  /// Per-running-session status keyed by session id — [workStatus] is only their
  /// rollup. Null for a cold core (or an older host); `{}` when nothing runs.
  final Map<String, AgentWorkStatus>? sessionStatuses;
  const ProjectSummary({
    required this.projectId,
    required this.path,
    required this.running,
    required this.mode,
    this.workStatus,
    this.sessionStatuses,
  });
}

/// One paired phone from `phones:list`. Mirror of control-protocol.ts PairedPhoneSummary.
class PairedPhoneSummary {
  final String phonePubkey;
  final String phoneDeviceId;
  final String? label;
  final String pairedAt;
  final String lastSeenAt;
  const PairedPhoneSummary({
    required this.phonePubkey,
    required this.phoneDeviceId,
    this.label,
    required this.pairedAt,
    required this.lastSeenAt,
  });

  factory PairedPhoneSummary.fromJson(Map<String, dynamic> json) {
    final phonePubkey = json['phonePubkey'];
    final phoneDeviceId = json['phoneDeviceId'];
    final pairedAt = json['pairedAt'];
    final lastSeenAt = json['lastSeenAt'];
    if (phonePubkey is! String ||
        phoneDeviceId is! String ||
        pairedAt is! String ||
        lastSeenAt is! String) {
      throw HostControlException('BAD_RESPONSE', 'malformed phone fields: $json');
    }
    return PairedPhoneSummary(
      phonePubkey: phonePubkey,
      phoneDeviceId: phoneDeviceId,
      label: json['label'] as String?,
      pairedAt: pairedAt,
      lastSeenAt: lastSeenAt,
    );
  }
}

/// One machine-known project from `phones:list`. Mirror of control-protocol.ts KnownProject.
class KnownProject {
  final String projectId;
  final String? label;
  final String? path;
  final bool running;
  const KnownProject({
    required this.projectId,
    this.label,
    this.path,
    required this.running,
  });

  factory KnownProject.fromJson(Map<String, dynamic> json) {
    final projectId = json['projectId'];
    if (projectId is! String) {
      throw HostControlException('BAD_RESPONSE', 'malformed project fields: $json');
    }
    return KnownProject(
      projectId: projectId,
      label: json['label'] as String?,
      path: json['path'] as String?,
      running: json['running'] == true,
    );
  }
}

/// `phones:list` response: paired phones + the machine's known project set.
class PhonesList {
  final List<PairedPhoneSummary> phones;
  final List<KnownProject> knownProjects;
  const PhonesList({required this.phones, required this.knownProjects});

  factory PhonesList.fromJson(Map<String, dynamic> json) {
    final rawPhones = (json['phones'] as List?) ?? const [];
    final rawProjects = (json['knownProjects'] as List?) ?? const [];
    return PhonesList(
      phones: rawPhones.map((e) {
        if (e is! Map) throw HostControlException('BAD_RESPONSE', 'malformed phone: $e');
        return PairedPhoneSummary.fromJson(e.cast<String, dynamic>());
      }).toList(growable: false),
      knownProjects: rawProjects.map((e) {
        if (e is! Map) throw HostControlException('BAD_RESPONSE', 'malformed project: $e');
        return KnownProject.fromJson(e.cast<String, dynamic>());
      }).toList(growable: false),
    );
  }
}

/// One installed tool from the loopback `tools:list`. Mirror of control-protocol.ts
/// ToolSummary. `chatCapable` and `label` are null against an older bridge that
/// predates each field; callers fall back to the app's static tables in that case.
class ToolSummary {
  final String tool;
  final String path;
  final bool? chatCapable;
  final String? label;
  const ToolSummary({
    required this.tool,
    required this.path,
    this.chatCapable,
    this.label,
  });
}

/// The machine-level remote-access policy: one boolean for the whole machine —
/// is it reachable from your other devices at all. Mirror of
/// control-protocol.ts RemoteAccessPolicy.
class RemoteAccessPolicy {
  final bool enabled;
  const RemoteAccessPolicy({required this.enabled});

  factory RemoteAccessPolicy.fromJson(Map<String, dynamic> json) =>
      RemoteAccessPolicy(enabled: json['enabled'] == true);
}

/// Thrown on a transport error, a non-200 status, or an `ok:false` body.
class HostControlException implements Exception {
  final String code;
  final String message;
  HostControlException(this.code, this.message);
  @override
  String toString() => 'HostControlException($code): $message';
}

/// Typed client for the bridge loopback control plane (unit 2/3a).
/// `POST http://127.0.0.1:<port>/control` with `Authorization: Bearer <token>`.
class HostControlClient {
  HostControlClient({
    required this.port,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final int port;
  final String token;
  final http.Client _http;

  // Monotonic request-id counter. The bridge echoes `id` back; we don't match
  // on it (one request per POST) but it must be present and non-empty.
  int _seq = 0;

  Uri get _uri => Uri.parse('http://127.0.0.1:$port/control');

  /// [timeout] bounds the loopback round-trip; callers size it to the verb's
  /// cost. A `TimeoutException` flows through the same `catch` as any transport
  /// error → `HostControlException('TRANSPORT')`, the type the open-path
  /// recovery invalidates + respawns on.
  Future<Map<String, dynamic>> _post(
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final id = '${++_seq}';
    http.Response res;
    try {
      res = await _http
          .post(
            _uri,
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer $token',
            },
            body: jsonEncode({'id': id, ...body}),
          )
          .timeout(timeout);
    } catch (e) {
      throw HostControlException('TRANSPORT', 'control POST failed: $e');
    }
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      decoded = const {};
    }
    if (decoded['ok'] != true) {
      final err = decoded['error'];
      if (err is Map) {
        throw HostControlException(
          (err['code'] as String?) ?? 'UNKNOWN',
          (err['message'] as String?) ?? '',
        );
      }
      if (res.statusCode != 200) {
        throw HostControlException(
          'HTTP_${res.statusCode}',
          'control returned ${res.statusCode}',
        );
      }
      throw HostControlException('UNKNOWN', 'control returned ok:false');
    }
    if (res.statusCode != 200) {
      throw HostControlException(
        'HTTP_${res.statusCode}',
        'control returned ${res.statusCode}',
      );
    }
    return decoded;
  }

  /// Opens a core for [projectId]. [mode] defaults to `local` — the desktop
  /// driver's only mode today (see design §Data plane) — but is a parameter so
  /// Phase B can request `remote` without a second near-duplicate method.
  Future<OpenResult> projectOpen({
    required String projectId,
    required String projectPath,
    String mode = 'local',
    // Longer ceiling: project:open does real host work (spawn terminals, walk
    // the file tree).
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final m = await _post({
      'type': 'project:open',
      'projectId': projectId,
      'projectPath': projectPath,
      'mode': mode,
    }, timeout: timeout);
    // Validate the connect block instead of casting blindly: a malformed/old
    // host (the version-skew attach case this design enables) must surface a
    // typed HostControlException, not a raw CastError the classifier can't read.
    final c = m['connect'];
    ConnectInfo? connect;
    if (c is Map) {
      final p = c['port'];
      final t = c['token'];
      if (p is int && t is String) {
        connect = ConnectInfo(port: p, token: t);
      } else {
        throw HostControlException(
          'BAD_RESPONSE',
          'malformed connect info (port=$p token=$t)',
        );
      }
    }
    return OpenResult(running: m['running'] == true, connect: connect);
  }

  Future<ResolvedLocalProject> projectResolve(
    String folder, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final m = await _post({'type': 'project:resolve', 'folder': folder}, timeout: timeout);
    return ResolvedLocalProject.fromJson(m);
  }

  /// The [HostController] liveness ping. Short timeout so a wedged host is
  /// detected fast instead of stalling the readiness poll / attach probe.
  Future<List<ProjectSummary>> projectList({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final m = await _post({'type': 'project:list'}, timeout: timeout);
    final raw = (m['projects'] as List?) ?? const [];
    return raw.map((e) {
      if (e is! Map) {
        throw HostControlException(
            'BAD_RESPONSE', 'malformed project entry: $e');
      }
      final id = e['projectId'];
      final path = e['path'];
      final mode = e['mode'];
      if (id is! String || path is! String || mode is! String) {
        throw HostControlException(
            'BAD_RESPONSE', 'malformed project fields: $e');
      }
      return ProjectSummary(
        projectId: id,
        path: path,
        running: e['running'] == true,
        mode: mode,
        workStatus: e['workStatus'] as String?,
        sessionStatuses: parseSessionStatuses(e['sessionStatuses']),
      );
    }).toList(growable: false);
  }

  Future<List<ToolSummary>> toolsList({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final m = await _post({'type': 'tools:list'}, timeout: timeout);
    final raw = (m['tools'] as List?) ?? const [];
    return raw.map((e) {
      if (e is! Map) {
        throw HostControlException('BAD_RESPONSE', 'malformed tool entry: $e');
      }
      final tool = e['tool'];
      final path = e['path'];
      if (tool is! String || path is! String) {
        throw HostControlException('BAD_RESPONSE', 'malformed tool fields: $e');
      }
      return ToolSummary(
        tool: tool,
        path: path,
        chatCapable: e['chatCapable'] as bool?,
        label: e['label'] as String?,
      );
    }).toList(growable: false);
  }

  Future<void> projectStop(String projectId) async {
    await _post({'type': 'project:stop', 'projectId': projectId});
  }

  /// Erase every machine-side trace of [projectId] (its persisted session store
  /// and the seen-catalog hint). Called on project
  /// delete so reopening the same folder doesn't reload the old sessions —
  /// `sessions.json` on the bridge is authoritative; the app only caches it.
  Future<void> projectForget(String projectId) async {
    await _post({'type': 'project:forget', 'projectId': projectId});
  }

  /// Ask the host to shut itself down gracefully (flush state, kill all PTYs,
  /// exit). Sent when the app window closes so the machine-level host daemon
  /// doesn't outlive the app. The host defers teardown until after this
  /// response, so the OK returns before the process exits.
  Future<void> hostShutdown() async {
    await _post({'type': 'host:shutdown'});
  }

  Future<PhonesList> phonesList({Duration timeout = const Duration(seconds: 3)}) async {
    final m = await _post({'type': 'phones:list'}, timeout: timeout);
    return PhonesList.fromJson(m);
  }

  Future<void> phonesUnpair({required String phonePubkey}) =>
      _post({'type': 'phones:unpair', 'phonePubkey': phonePubkey});

  /// The `mobile-access:` verb spelling is the wire contract, deliberately left
  /// behind the Dart rename: the app talks to whatever bridge binary is
  /// installed on the machine, which may predate this app build.
  Future<RemoteAccessPolicy> remoteAccessGet({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final m = await _post({'type': 'mobile-access:get'}, timeout: timeout);
    return RemoteAccessPolicy.fromJson(m);
  }

  /// Turn remote access on or off for the whole machine. Returns the resulting
  /// state as the bridge sees it, so the caller never has to assume the write
  /// landed as requested.
  Future<RemoteAccessPolicy> remoteAccessSet(bool enabled) async {
    final m = await _post({'type': 'mobile-access:set', 'enabled': enabled});
    return RemoteAccessPolicy.fromJson(m);
  }

  Future<GitBranchCatalog> gitBranches({
    required String projectId,
    required String projectPath,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final m = await _post({
      'type': 'git:branches',
      'projectId': projectId,
      'projectPath': projectPath,
    }, timeout: timeout);
    try {
      return GitBranchCatalog.fromJson(m);
    } catch (e) {
      throw HostControlException('BAD_RESPONSE', 'malformed git:branches response: $e');
    }
  }

  Future<String> gitCheckout({
    required String projectId,
    required String projectPath,
    required String branch,
    bool allowActiveSessions = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final m = await _post({
      'type': 'git:checkout',
      'projectId': projectId,
      'projectPath': projectPath,
      'branch': branch,
      'allowActiveSessions': allowActiveSessions,
    }, timeout: timeout);
    final current = m['current'];
    if (current is! String) {
      throw HostControlException('BAD_RESPONSE', 'malformed git:checkout current: $m');
    }
    return current;
  }

  /// Absolute working directory of one checkout — `main` for a shared session,
  /// the managed worktree for an isolated one. Paths are host-local everywhere
  /// else (they are deliberately absent from `SessionEntry`); this loopback verb
  /// is the only way the desktop learns one, so it may only ever be used for a
  /// LOCAL project.
  Future<String> checkoutPath({
    required String projectId,
    required String checkoutId,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final m = await _post({
      'type': 'checkout:path',
      'projectId': projectId,
      'checkoutId': checkoutId,
    }, timeout: timeout);
    final path = m['path'];
    if (path is! String || path.isEmpty) {
      throw HostControlException('BAD_RESPONSE', 'malformed checkout:path response: $m');
    }
    return path;
  }

  void close() => _http.close();
}
