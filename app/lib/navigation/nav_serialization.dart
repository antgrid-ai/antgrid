// app/lib/navigation/nav_serialization.dart
import '../models/session_target.dart';
import '../providers/ui_attention_providers.dart' show WorkbenchSurface;
import 'nav_location.dart';

/// Encodes a [NavLocation] as an `antgrid://nav/...` deep link. Sibling of the
/// existing `antgrid://auth/...` scheme; see the design spec for the grammar.
Uri navLocationToUri(NavLocation loc) {
  final target = loc.target;
  final query = <String, String>{};
  if (loc.sessionId != null) query['session'] = loc.sessionId!;

  switch (target) {
    case null:
      // Surface-only locations (settings/devices).
      final seg = switch (loc.surface) {
        WorkbenchSurface.appSettings => 'settings',
        WorkbenchSurface.mobileDevices => 'devices',
        // workspace/newSession with no project is not a meaningful deep link;
        // encode defensively as settings-less root.
        _ => 'workspace',
      };
      return Uri(scheme: 'antgrid', host: 'nav', pathSegments: [seg]);
    case LocalProject(:final projectId):
      query['surface'] = loc.surface.name;
      return Uri(
        scheme: 'antgrid',
        host: 'nav',
        pathSegments: ['local', projectId],
        queryParameters: query,
      );
    case RemoteProject(:final machineUuid, :final projectId):
      query['surface'] = loc.surface.name;
      return Uri(
        scheme: 'antgrid',
        host: 'nav',
        pathSegments: ['remote', machineUuid, projectId],
        queryParameters: query,
      );
    case RemoteTarget(:final agentDeviceId):
      query['surface'] = loc.surface.name;
      return Uri(
        scheme: 'antgrid',
        host: 'nav',
        pathSegments: ['agent', agentDeviceId],
        queryParameters: query,
      );
  }
}

/// Parses an `antgrid://nav/...` deep link back into a [NavLocation].
/// Returns null for any non-`nav` host or unrecognized/short path.
///
/// A deep link is untrusted external input, so this rejects anything that is
/// not exactly `antgrid://nav/...` (a foreign scheme whose host happens to be
/// `nav` must not drive navigation) and any blank path segment. The target it
/// yields is still only a focus request — actually connecting to a project
/// stays gated by pairing/license downstream — but the parse must not produce a
/// target from malformed input.
NavLocation? navLocationFromUri(Uri uri) {
  if (uri.scheme != 'antgrid' || uri.host != 'nav') return null;
  final segs = uri.pathSegments;
  if (segs.isEmpty || segs.any((s) => s.trim().isEmpty)) return null;

  final session = uri.queryParameters['session'];
  WorkbenchSurface surfaceFromQuery() {
    final raw = uri.queryParameters['surface'];
    return WorkbenchSurface.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => WorkbenchSurface.workspace,
    );
  }

  switch (segs.first) {
    case 'settings':
      return const NavLocation(
        target: null,
        surface: WorkbenchSurface.appSettings,
      );
    case 'devices':
      return const NavLocation(
        target: null,
        surface: WorkbenchSurface.mobileDevices,
      );
    case 'workspace':
      // Symmetric with the defensive null-target encoding in navLocationToUri.
      return const NavLocation(
        target: null,
        surface: WorkbenchSurface.workspace,
      );
    case 'local':
      if (segs.length < 2) return null;
      return NavLocation(
        target: LocalProject(segs[1]),
        surface: surfaceFromQuery(),
        sessionId: session,
      );
    case 'remote':
      if (segs.length < 3) return null;
      return NavLocation(
        target: RemoteProject(machineUuid: segs[1], projectId: segs[2]),
        surface: surfaceFromQuery(),
        sessionId: session,
      );
    case 'agent':
      if (segs.length < 2) return null;
      return NavLocation(
        target: RemoteTarget.legacy(segs[1]),
        surface: surfaceFromQuery(),
        sessionId: session,
      );
    default:
      return null;
  }
}
