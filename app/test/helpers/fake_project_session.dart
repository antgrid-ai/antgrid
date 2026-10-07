import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';

import 'fake_agent_transport.dart';

/// A local-mode [ProjectSession] over [transport], disposing it on close.
/// Opens a real [CachedSessionsStore], so a widget test calls this inside
/// `tester.runAsync`.
Future<ProjectSession> newFakeProjectSession(
  FakeAgentTransport transport, {
  String projectId = 'p',
}) async {
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: projectId,
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
}
