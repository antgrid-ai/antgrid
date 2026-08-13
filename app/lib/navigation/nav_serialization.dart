// app/lib/navigation/nav_serialization.dart
import 'package:collection/collection.dart';

import '../models/session_target.dart';
import '../models/settings_section.dart';
import '../models/workspace_view.dart';
import '../providers/ui_attention_providers.dart' show WorkbenchSurface;
import 'nav_location.dart';

/// Encodes a [NavLocation] as an `antgrid://nav/...` deep link. Sibling of the
/// existing `antgrid://auth/...` scheme; see the design spec for the grammar.
Uri navLocationToUri(NavLocation loc) {
  final target = loc.target;
  final query = <String, String>{};
  // Session, view and file each name something *inside* a project, which is why
  // the null-target branch below builds a Uri with no query at all: there is no
  // workspace to address. Each is omitted when null, so a location naming none
  // encodes to a link carrying no trace of it — already-written links must keep
  // decoding to the same location.
  if (loc.sessionId != null) query['session'] = loc.sessionId!;
  if (loc.view != null) query['view'] = loc.view!.name;
  if (loc.file != null) query['file'] = loc.file!;
  if (loc.settingsSection != null) {
    query['section'] = loc.settingsSection!.name;
  }

  switch (target) {
    case null:
      // Surface-only locations (settings/devices).
      final seg = switch (loc.surface) {
        WorkbenchSurface.appSettings => 'settings',
        WorkbenchSurface.remoteDevices => 'devices',
        // workspace/newSession with no project is not a meaningful deep link;
        // encode defensively as settings-less root.
        _ => 'workspace',
      };
      // The one query param that survives a project-less location: a section
      // names a block of the settings screen, which is right here, unlike
      // session/view. Omitted when null, so a settings location naming no
      // section is exactly `antgrid://nav/settings`.
      final section = seg == 'settings' ? loc.settingsSection : null;
      return Uri(
        scheme: 'antgrid',
        host: 'nav',
        pathSegments: [seg],
        queryParameters: section == null ? null : {'section': section.name},
      );
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

/// Matches the Windows drive-letter root a bridge would resolve as absolute.
final _windowsDriveRoot = RegExp(r'^[A-Za-z]:');

/// Whether [path] is a file the explorer may open, i.e. one that stays inside
/// the checkout it will be resolved against.
///
/// Sanitising is deliberately NOT on offer: a link that tries to climb out of
/// the checkout is hostile rather than stale, so [navLocationFromUri] refuses
/// the whole link instead of quietly rewriting the path into a different file.
/// This runs on the DECODED query value, which is the only point where a
/// `%2e%2e%2f` is visible as `../`.
bool _isCheckoutRelativeFile(String path) {
  // The file tree speaks POSIX separators (`FileNode.path`), so a backslash is
  // never a separator here — `..\x` would sail past the segment scan below and
  // still climb a directory on a Windows bridge. Refusing it also covers UNC
  // roots.
  if (path.contains('\\')) return false;
  if (path.startsWith('/') || _windowsDriveRoot.hasMatch(path)) return false;
  final segments = path.split('/');
  // Refusing every all-dots-and-whitespace segment covers two cases at once: a
  // blank one, which names nothing (and is what rejects a bare `file=`), and
  // every spelling of the parent directory. An exact `..` test would not reach
  // the second — Win32 strips trailing dots and spaces from a path component,
  // so `.. ` and `...` climb a directory on a Windows bridge for the same
  // reason the backslash above does. Nothing legitimate is named only dots and
  // spaces, so this costs no real path.
  return !segments.any(_dotsAndSpacesOnly.hasMatch);
}

/// A path segment carrying no name — empty, or only dots and whitespace.
final _dotsAndSpacesOnly = RegExp(r'^[.\s]*$');

/// Parses an `antgrid://nav/...` deep link back into a [NavLocation].
/// Returns null for any non-`nav` host or unrecognized/short path.
///
/// A deep link is untrusted external input, so this rejects anything that is
/// not exactly `antgrid://nav/...` (a foreign scheme whose host happens to be
/// `nav` must not drive navigation), any blank path segment, and any `file=`
/// that could escape the checkout. The target it yields is still only a focus
/// request — actually connecting to a project stays gated by pairing/license
/// downstream — but the parse must not produce a target from malformed input.
NavLocation? navLocationFromUri(Uri uri) {
  if (uri.scheme != 'antgrid' || uri.host != 'nav') return null;
  final List<String> segs;
  final Map<String, String> query;
  try {
    segs = uri.pathSegments;
    query = uri.queryParameters;
  } on FormatException {
    // Both getters percent-DECODE, and an escape that is not valid UTF-8
    // (`antgrid://nav/local/%80`) throws out of them rather than degrading.
    // The link arrives from the OS and is applied fire-and-forget, so a throw
    // here is an unhandled async error — a refused link is the contract.
    return null;
  }
  if (segs.isEmpty || segs.any((s) => s.trim().isEmpty)) return null;

  // Structure, not value: an unusable `view=`/`section=` degrades to null
  // below, but an escaping path fails the whole link — checked before the
  // segment switch so no branch can hand one on, and so a link carrying one is
  // refused even where the file itself would have been ignored.
  final file = query['file'];
  if (file != null && !_isCheckoutRelativeFile(file)) return null;

  final session = query['session'];
  WorkbenchSurface surfaceFromQuery() {
    final raw = query['surface'];
    return WorkbenchSurface.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => WorkbenchSurface.workspace,
    );
  }

  // Absent and unrecognised collapse to the same answer — no tab named, so the
  // tab already up survives — which is what lets an older app open a link that
  // names a view it has never heard of instead of refusing it. Same
  // degrade-on-bad-value contract as surfaceFromQuery; malformed *structure* is
  // still rejected above.
  WorkspaceView? viewFromQuery() {
    final raw = query['view'];
    return WorkspaceView.values.firstWhereOrNull((v) => v.name == raw);
  }

  // Same degrade-on-bad-value contract as the two above: a section this build
  // has never heard of leaves the settings screen where it opens rather than
  // failing the whole link.
  SettingsSection? sectionFromQuery() {
    final raw = query['section'];
    return SettingsSection.values.firstWhereOrNull((s) => s.name == raw);
  }

  switch (segs.first) {
    case 'settings':
      return NavLocation(
        target: null,
        surface: WorkbenchSurface.appSettings,
        settingsSection: sectionFromQuery(),
      );
    case 'devices':
      return const NavLocation(
        target: null,
        surface: WorkbenchSurface.remoteDevices,
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
        view: viewFromQuery(),
        settingsSection: sectionFromQuery(),
        file: file,
      );
    case 'remote':
      if (segs.length < 3) return null;
      return NavLocation(
        target: RemoteProject(machineUuid: segs[1], projectId: segs[2]),
        surface: surfaceFromQuery(),
        sessionId: session,
        view: viewFromQuery(),
        settingsSection: sectionFromQuery(),
        file: file,
      );
    case 'agent':
      if (segs.length < 2) return null;
      return NavLocation(
        target: RemoteTarget.legacy(segs[1]),
        surface: surfaceFromQuery(),
        sessionId: session,
        view: viewFromQuery(),
        settingsSection: sectionFromQuery(),
        file: file,
      );
    default:
      return null;
  }
}
