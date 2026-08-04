import 'package:url_launcher/url_launcher.dart';

import '../design/ab_icons.dart';

/// An external desktop application a checkout directory can be handed to.
///
/// Every target is reached through a URL scheme, never a spawned process: the
/// app builds no command line, so a directory containing spaces, quotes or
/// shell metacharacters is inert rather than something to escape.
enum ExternalOpenTarget {
  fileManager(
    label: 'Open folder',
    appName: 'the folder',
    icon: AbIcons.folder,
    scheme: null,
  ),
  vscode(
    label: 'Open in VS Code',
    appName: 'VS Code',
    icon: AbIcons.code,
    scheme: 'vscode',
  ),
  cursor(
    label: 'Open in Cursor',
    appName: 'Cursor',
    icon: AbIcons.code,
    scheme: 'cursor',
  ),
  windsurf(
    label: 'Open in Windsurf',
    appName: 'Windsurf',
    icon: AbIcons.code,
    scheme: 'windsurf',
  );

  const ExternalOpenTarget({
    required this.label,
    required this.appName,
    required this.icon,
    required this.scheme,
  });

  /// Menu row text.
  final String label;

  /// The app's name as it reads mid-sentence, for failure messages.
  final String appName;

  final String icon;

  /// URL scheme the editor registers with the OS, or null for the file manager
  /// (reached via `file:`).
  final String? scheme;

  /// The URI that opens [path] in this target.
  ///
  /// Editors take the `<scheme>://file/<path>` form VS Code introduced and its
  /// forks kept. [Uri] percent-encodes the path for us, and each platform's
  /// launcher decodes it again.
  Uri uriFor(String path) => scheme == null
      ? Uri.file(path)
      : Uri(scheme: scheme, host: 'file', path: _schemePath(path));
}

/// Reshape an OS path into the absolute, POSIX-shaped path an editor scheme
/// expects: `C:\repo` → `/C:/repo`, `/home/x/repo` → `/home/x/repo`. The drive
/// letter keeps its colon — VS Code parses it back out.
String _schemePath(String path) {
  final slashed = path.replaceAll(r'\', '/');
  return slashed.startsWith('/') ? slashed : '/$slashed';
}

/// Only the scheme reaches the OS lookup on every desktop platform, so any
/// absolute-looking path probes correctly.
const _probePath = '/';

/// The subset of [ExternalOpenTarget] this machine can actually open.
///
/// [fileManager] is never probed and always included. Every desktop OS has one,
/// and the probe does not actually measure that: Windows answers `canLaunchUrl`
/// from a `URL Protocol` registration under `HKEY_CLASSES_ROOT\file`, which is
/// a separate thing from whether `ShellExecuteW` can open a directory — so a
/// machine missing that registration would lose a target that works.
Future<List<ExternalOpenTarget>> detectExternalOpenTargets() async {
  final found = <ExternalOpenTarget>[];
  for (final target in ExternalOpenTarget.values) {
    if (target.scheme == null) {
      found.add(target);
      continue;
    }
    bool available;
    try {
      available = await canLaunchUrl(target.uriFor(_probePath));
    } catch (_) {
      available = false;
    }
    if (available) found.add(target);
  }
  return found;
}
