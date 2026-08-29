// The paused -> resumed edge, and the ordering it exists to guarantee.
//
// Unpausing does not re-establish the transport, so the tier-3 hydrators never
// run for a foreground: this edge is the only recovery signal a surface that
// rebuilds from snapshots has after the agent has spent the background dropping
// its output. It is raised on the UNION the agent actually gates on
// (`_lifecyclePaused || !_heavyListened`) and only after the declaration is on
// the wire, because a pull that overtakes the declaration is answered into a
// window where the agent is still suppressing.

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/message_router.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  test('a lifecycle pause then resume raises exactly one edge', () async {
    final t = FakeAgentTransport();
    final router = MessageRouter(transport: t);
    final edges = <void>[];
    final resumeSub = router.focusResumed.listen(edges.add);
    // A heavy subscriber is half the union: without one the router declares
    // paused regardless of the lifecycle, and there is no edge to raise.
    final heavySub = router.heavy.listen((_) {});
    await Future<void>.delayed(Duration.zero);

    router.setLifecyclePaused(true);
    router.setLifecyclePaused(false);
    await Future<void>.delayed(Duration.zero);

    expect(edges, hasLength(1));

    await resumeSub.cancel();
    await heavySub.cancel();
    await router.dispose();
    await t.dispose();
  });

  test('resuming an already-unpaused router raises nothing', () async {
    final t = FakeAgentTransport();
    final router = MessageRouter(transport: t);
    final edges = <void>[];
    final resumeSub = router.focusResumed.listen(edges.add);
    final heavySub = router.heavy.listen((_) {});
    await Future<void>.delayed(Duration.zero);

    router.setLifecyclePaused(false);
    await Future<void>.delayed(Duration.zero);

    expect(edges, isEmpty);

    await resumeSub.cancel();
    await heavySub.cancel();
    await router.dispose();
    await t.dispose();
  });

  test('resyncFocusState re-declares a pause without raising an edge', () async {
    // A fresh stream is re-establishment, which the hydrators already own; the
    // router stays free of terminal semantics.
    final t = FakeAgentTransport();
    final router = MessageRouter(transport: t);
    final edges = <void>[];
    final resumeSub = router.focusResumed.listen(edges.add);
    final heavySub = router.heavy.listen((_) {});
    router.setLifecyclePaused(true);
    await Future<void>.delayed(Duration.zero);

    t.clearSent();
    router.resyncFocusState();
    await Future<void>.delayed(Duration.zero);

    final declarations = t.sent.where((m) => m['type'] == 'client:focus-state');
    expect(declarations, hasLength(1));
    expect(declarations.first['paused'], isTrue);
    expect(edges, isEmpty);

    await resumeSub.cancel();
    await heavySub.cancel();
    await router.dispose();
    await t.dispose();
  });

  test('the resume declaration is enqueued before every snapshot pull it '
      'triggers', () async {
    final t = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    );
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {'id': 'a', 'terminalId': 'a', 'name': 'a', 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    session.setLifecyclePaused(true);
    await Future<void>.delayed(Duration.zero);
    t.clearSent();

    session.setLifecyclePaused(false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final declaredAt = t.sent.indexWhere(
      (m) => m['type'] == 'client:focus-state' && m['paused'] == false,
    );
    expect(declaredAt, isNonNegative);
    final pullIndices = [
      for (var i = 0; i < t.sent.length; i++)
        if (t.sent[i]['type'] == 'terminal:snapshot:request') i,
    ];
    expect(pullIndices, isNotEmpty);
    expect(pullIndices.every((i) => i > declaredAt), isTrue);

    await session.close();
  });
}
