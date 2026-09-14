// app/lib/launcher/project_resolve.dart
import 'host_control_client.dart';
import 'project_id.dart';
import '../util/path_basename.dart';

/// Resolves [folder]'s repository identity via the host's `project:resolve`
/// verb, falling back to the app-side path hash for a bridge that predates it
/// (older hosts answer `BAD_REQUEST`/`UNKNOWN_VERB`). Every other
/// [HostControlException] — and every other error type — propagates: those
/// mean the host is reachable but something else is wrong, not that the verb
/// is missing.
///
/// Does not own [client]; the caller closes it.
Future<ResolvedLocalProject> resolveLocalProject(
  HostControlClient client,
  String folder,
) async {
  try {
    return await client.projectResolve(folder);
  } on HostControlException catch (e) {
    if (e.code != 'BAD_REQUEST' && e.code != 'UNKNOWN_VERB') rethrow;
    return ResolvedLocalProject(
      projectId: await computeProjectId(folder),
      repoPath: folder,
      selectedPath: folder,
      label: pathBasename(folder),
      isGitRepository: false,
      kind: 'plain',
    );
  }
}
