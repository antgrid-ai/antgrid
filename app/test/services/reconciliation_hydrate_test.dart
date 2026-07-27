// Tier-3 re-drive contract at the service layer.
//
// The reconciliation-checkpoint principle: idempotent view-state (the session
// list, the config, the open file) must be re-pulled on every (re)establishment
// so a reconnect shows live state instead of whatever was on screen when the
// stream dropped. Each service registers a hydrator at construction via
// `session.hydrate(...)`; this test drives `FakeAgentTransport.redriveHydrators`
// (what StreamTransport.refreshSnapshot does on each handshake) and asserts the
// pull re-fires — and that closing the file DEregisters its hydrator.
//
// Non-vacuous by construction: each case clears the outbound log first and
// asserts it is empty, so the post-redrive send can only have come from the
// re-drive.

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> makeSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    );
  }

  List<Map<String, dynamic>> sentOf(FakeAgentTransport t, String type) =>
      t.sent.where((m) => m['type'] == type).toList();

  test('sessions:list re-fires on re-establishment', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    // The constructor hydrator fired once (the fake is established).
    expect(sentOf(t, 'session:list'), hasLength(1));

    t.clearSent();
    expect(sentOf(t, 'session:list'), isEmpty);
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    expect(sentOf(t, 'session:list'), hasLength(1));
    await session.close();
  });

  test('config:read re-fires on re-establishment', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    expect(sentOf(t, 'config:read'), hasLength(1));

    t.clearSent();
    expect(sentOf(t, 'config:read'), isEmpty);
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    expect(sentOf(t, 'config:read'), hasLength(1));
    await session.close();
  });

  test('open file re-fires file:read on re-establishment', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    t.clearSent();

    // Selecting registers the hydrator, which fires now (established).
    session.fileService.selectFile('lib/foo.dart');
    await Future<void>.delayed(Duration.zero);
    expect(sentOf(t, 'file:read'), hasLength(1));
    expect(sentOf(t, 'file:read').first['path'], 'lib/foo.dart');

    t.clearSent();
    expect(sentOf(t, 'file:read'), isEmpty);
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    final reads = sentOf(t, 'file:read');
    expect(reads, hasLength(1));
    expect(reads.first['path'], 'lib/foo.dart');
    await session.close();
  });

  test('re-selecting a different file re-drives the NEW file', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);

    session.fileService.selectFile('a.dart');
    session.fileService.selectFile('b.dart');
    await Future<void>.delayed(Duration.zero);

    t.clearSent();
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    final reads = sentOf(t, 'file:read');
    expect(reads, hasLength(1));
    expect(reads.first['path'], 'b.dart');
    await session.close();
  });

  test('closing the file deregisters its hydrator', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);

    session.fileService.selectFile('lib/foo.dart');
    await Future<void>.delayed(Duration.zero);

    session.fileService.clearViewingFile();
    t.clearSent();
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    expect(sentOf(t, 'file:read'), isEmpty);
    await session.close();
  });
}
