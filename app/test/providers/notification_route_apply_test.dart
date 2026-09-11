// Applying a tapped notification's route is the one place several separately
// documented rules meet, and each of them fails silently: a pending session
// id written for the ALREADY-focused project is never drained and suppresses
// `reconcileActiveSession`'s fallback; a surface revealed by call rather than
// by handover is undone a frame later by the per-session UI restore; and a
// dedup store shared with the toast's own would make every tap a no-op.
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/notification_route.dart';
import 'package:antgrid/navigation/root_navigator.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/providers/notification_route_apply.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _localUuid = 'this-machine';
const _projectId = 'proj-1';
const _sessionId = 'session-1';

SessionEntry _entry(String id, {bool deleting = false}) => SessionEntry(
  id: id,
  name: id,
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  deleting: deleting,
);

RecentSessionRow _row(SessionEntry session, {String projectId = _projectId}) =>
    RecentSessionRow(
      session: session,
      origin: RecentOrigin(
        isLocal: true,
        registrationId: projectId,
        projectId: projectId,
        machineUuid: null,
        projectName: projectId,
        deviceName: 'this machine',
      ),
    );

/// [sessions] seeds both universes — the project's live list and the Recent
/// rows. [noLiveList] is the pre-bootstrap state, where no list has landed for
/// this project at all.
ProviderContainer _container({
  required List<SessionEntry> sessions,
  SessionTarget? focused,
  bool noLiveList = false,
  List<Override> extraOverrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      localDeviceUuidProvider.overrideWith((_) async => _localUuid),
      recentSessionsProvider.overrideWithValue([
        for (final s in sessions) _row(s),
      ]),
      // The real one resolves a per-project session graph; the write guard on
      // `activeSessionIdProvider` is the only thing that reads it here.
      freshSessionsStateProvider.overrideWithValue(
        noLiveList
            ? null
            : SessionsState(projectId: _projectId, sessions: sessions),
      ),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  if (focused != null) {
    container.read(selectedTargetProvider.notifier).set(focused);
  }
  return container;
}

/// A context for the paths that reach `activateDrawerEntryById`, which takes a
/// widget context for its own snackbars and drawer pop. Nothing here renders
/// the app — the applier is driven against the container directly.
Future<BuildContext> _someContext(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  return tester.element(find.byType(SizedBox));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The default desktop case, and the one that used to strand the app: a
  // pending id here is never drained (the bootstrap's listener returns on an
  // unchanged project) and makes `reconcileActiveSession` select null instead
  // of falling back once the session leaves the list.
  test('a focused-project route selects the session directly', () async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject(_projectId),
    );

    final applied = await applyNotificationRoute(
      null,
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'agent',
      ),
    );

    expect(applied, isTrue);
    expect(container.read(activeSessionIdProvider), _sessionId);
    expect(container.read(pendingActiveSessionIdProvider), isNull);
    expect(container.read(pendingSessionStartSuppressedIdProvider), isNull);
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
  });

  // The transcript is not a workspace tab, so an agent-kind route hands over
  // the agent page; a handler-kind one hands over the tab instead. Never both.
  test('agent hands over the page, handler hands over the tab', () async {
    final agent = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject(_projectId),
    );
    await applyNotificationRoute(
      null,
      agent,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'agent',
      ),
    );
    expect(agent.read(pendingAgentPageProvider), (
      target: const LocalProject(_projectId),
      value: true,
    ));
    expect(agent.read(pendingWorkspaceViewProvider), isNull);

    final handler = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject(_projectId),
    );
    await applyNotificationRoute(
      null,
      handler,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'handler',
      ),
    );
    expect(handler.read(pendingWorkspaceViewProvider), (
      target: const LocalProject(_projectId),
      value: WorkspaceView.handler,
    ));
    expect(handler.read(pendingAgentPageProvider), isNull);
  });

  // The write is silently refused for a session the bridge is deleting, so the
  // applier reads it back — revealing that session's surface afterwards would
  // aim the workspace at a transcript nobody is going to be shown. The project
  // is still a destination, so the surface still moves: reporting success from
  // the settings screen without leaving it explains nothing to the user.
  test('a deleting session reaches the project but stamps no surface', () async {
    final container = _container(
      sessions: [_entry('other'), _entry(_sessionId, deleting: true)],
      focused: const LocalProject(_projectId),
    );
    container.read(activeSessionIdProvider.notifier).set('other');
    container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.appSettings);
    // A tab an earlier navigation left pending: this destination inherits
    // nothing, so it is dropped rather than drained in the session's place.
    container.read(pendingWorkspaceViewProvider.notifier).set((
      target: const LocalProject(_projectId),
      value: WorkspaceView.git,
    ));

    final applied = await applyNotificationRoute(
      null,
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'handler',
      ),
    );

    expect(applied, isTrue);
    expect(container.read(activeSessionIdProvider), 'other');
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
    expect(container.read(pendingWorkspaceViewProvider), isNull);
    expect(container.read(pendingAgentPageProvider), isNull);
    // Only the session-scoped half was skipped. History still has to name the
    // place the user was just moved to, carrying the session actually in
    // focus — otherwise `back()` re-applies the entry before this one and
    // silently discards the move.
    final nav = container.read(navControllerProvider);
    expect(nav.current?.target, const LocalProject(_projectId));
    expect(nav.current?.surface, WorkbenchSurface.workspace);
    expect(nav.current?.sessionId, 'other');
  });

  // Only a session it can SEE as deleting is refused. An id the app does not
  // recognise is written through by design ([ActiveSessionId]) — the list lands
  // in stages, and a guard demanding presence would drop every selection made
  // before it does, which is the ordinary case and the whole point of the wave.
  test('a session named before any list landed is still selected', () async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject(_projectId),
      noLiveList: true,
    );

    final applied = await applyNotificationRoute(
      null,
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'agent',
      ),
    );

    expect(applied, isTrue);
    expect(container.read(activeSessionIdProvider), _sessionId);
  });

  testWidgets('a cross-project route opens the project and queues the session', (
    tester,
  ) async {
    useInMemoryPrefs();
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);
    final project = AbProject(
      projectId: _projectId,
      folder: '/repos/$_projectId',
      displayName: _projectId,
      hostDeviceUuid: _localUuid,
      hostMachineName: 'This machine',
      lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject('somewhere-else'),
      extraOverrides: [
        ...stores.overrides,
        // A local entry activates synchronously through `selectProject`, so the
        // success path needs no navigator and no live transport.
        drawerEntriesProvider.overrideWithValue([LocalProjectEntry(project)]),
      ],
    );
    // Both halves of the queued state, so the assertion is about the MECHANISM:
    // nothing else in the suite proves the applier ever SETS the suppressor,
    // and deleting that write would otherwise leave the suite green.
    final queued = <String?>[];
    final suppressed = <String?>[];
    final subs = [
      container.listen(pendingActiveSessionIdProvider, (_, n) => queued.add(n)),
      container.listen(
        pendingSessionStartSuppressedIdProvider,
        (_, n) => suppressed.add(n),
      ),
    ];
    addTearDown(() {
      for (final s in subs) {
        s.close();
      }
    });

    final applied = await applyNotificationRoute(
      await _someContext(tester),
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'handler',
      ),
    );

    expect(applied, isTrue);
    expect(
      container.read(selectedTargetProvider),
      const LocalProject(_projectId),
    );
    expect(queued, [_sessionId]);
    expect(
      suppressed,
      [_sessionId],
      reason: 'a tap says show me, never resume — and it says it for THIS id',
    );
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
    // Stamped with the target it just moved to, not the one it left.
    expect(container.read(pendingWorkspaceViewProvider), (
      target: const LocalProject(_projectId),
      value: WorkspaceView.handler,
    ));
    // `recordProjectFocus` stands down while a session activation is queued, so
    // the applier's own commit is the only entry one tap records.
    final nav = container.read(navControllerProvider);
    expect(nav.current?.target, const LocalProject(_projectId));
    expect(nav.current?.sessionId, _sessionId);
    expect(nav.past, isEmpty);
  });

  // A cross-project route queues the session for `_bootstrapSessions` instead
  // of writing it, and the suppressor rides with that id — so an activation
  // that never lands must put back exactly what it found.
  testWidgets('a failed cross-project activation restores what it borrowed', (
    tester,
  ) async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject('somewhere-else'),
      extraOverrides: [drawerEntriesProvider.overrideWithValue(const [])],
    );
    // Another site's queued pick. The applier is borrowing this state, so a
    // failure owes it back rather than nulling it.
    container.read(pendingActiveSessionIdProvider.notifier).set('someone-elses');

    // No drawer entry and a bare (non-compound) id, so neither the warm-refocus
    // nor the cold-open path can do anything — the shape of a machine asleep.
    final applied = await applyNotificationRoute(
      await _someContext(tester),
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
        kind: 'agent',
      ),
    );

    expect(applied, isFalse);
    expect(container.read(pendingActiveSessionIdProvider), 'someone-elses');
    expect(container.read(pendingSessionStartSuppressedIdProvider), isNull);
    expect(container.read(activeSessionIdProvider), isNull);
  });

  // The toast is still on screen when this returns, so its retry has to be able
  // to reach the applier again — a claim taken and burnt makes every later
  // press a silent no-op.
  testWidgets('a failed activation can be retried', (tester) async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject('somewhere-else'),
      extraOverrides: [drawerEntriesProvider.overrideWithValue(const [])],
    );
    const route = NotificationRoute(
      registrationId: _projectId,
      terminalId: _sessionId,
      sourceMessageId: 'msg-1',
    );
    final context = await _someContext(tester);

    expect(await applyNotificationRoute(context, container, route), isFalse);
    // The retry reaches the resolver again rather than the dedup.
    final queued = <String?>[];
    final sub = container.listen(
      pendingActiveSessionIdProvider,
      (_, next) => queued.add(next),
    );
    addTearDown(sub.close);
    expect(await applyNotificationRoute(context, container, route), isFalse);
    expect(queued, isNotEmpty, reason: 'the second press got as far as queueing');
  });

  // Nothing can dial a project without a context, so seeding the queued state
  // there would clobber another site's pick to attempt nothing at all.
  testWidgets('a context-less cross-project route queues nothing and stays '
      'retryable', (tester) async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject('somewhere-else'),
      extraOverrides: [drawerEntriesProvider.overrideWithValue(const [])],
    );
    final queued = <String?>[];
    final sub = container.listen(
      pendingActiveSessionIdProvider,
      (_, next) => queued.add(next),
    );
    addTearDown(sub.close);
    const route = NotificationRoute(
      registrationId: _projectId,
      terminalId: _sessionId,
    );

    expect(await applyNotificationRoute(null, container, route), isFalse);
    expect(queued, isEmpty);

    // The claim this path took was given back, so the same route reaches the
    // activation once a live context arrives. A burnt one returns false at the
    // dedup with nothing queued — indistinguishable from the answer above, and
    // the reason that assertion alone does not pin the release.
    expect(
      await applyNotificationRoute(
        await _someContext(tester),
        container,
        route,
      ),
      isFalse,
    );
    expect(queued, isNotEmpty, reason: 'the retry got as far as queueing');
  });

  // The claim doubles as the in-flight guard, so a THROW owes it back like
  // every other exit: `localDeviceUuidProvider` is built to REJECT rather than
  // stall on a keychain read error, and the toast runs the applier detached, so
  // the throw is only logged. An unreleased claim there is a chip that can
  // never work again for the life of the container.
  test('a throwing apply leaves the route retryable', () async {
    var failing = true;
    final container = ProviderContainer(
      overrides: [
        // An `Error`, not an `Exception`: Riverpod 3 does not retry Errors, so
        // `.future` rejects here the way `noProviderRetry` makes production's
        // every failure reject.
        localDeviceUuidProvider.overrideWith((_) async {
          if (failing) throw StateError('keychain unreadable');
          return _localUuid;
        }),
        recentSessionsProvider.overrideWithValue([_row(_entry(_sessionId))]),
        freshSessionsStateProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(selectedTargetProvider.notifier)
        .set(const LocalProject(_projectId));
    const route = NotificationRoute(
      registrationId: _projectId,
      terminalId: _sessionId,
      sourceMessageId: 'msg-1',
    );

    await expectLater(
      applyNotificationRoute(null, container, route),
      throwsStateError,
    );

    failing = false;
    container.invalidate(localDeviceUuidProvider);

    expect(await applyNotificationRoute(null, container, route), isTrue);
    expect(container.read(activeSessionIdProvider), _sessionId);
  });

  // Applying a route is what unmounts the shell the toast's callback captured,
  // so a dead element is the ordinary state by the time the applier reads it —
  // and the app's one Navigator, which outlives every route, is what it falls
  // back to.
  testWidgets('an unmounted context falls back to the root navigator', (
    tester,
  ) async {
    useInMemoryPrefs();
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);
    final project = AbProject(
      projectId: _projectId,
      folder: '/repos/$_projectId',
      displayName: _projectId,
      hostDeviceUuid: _localUuid,
      hostMachineName: 'This machine',
      lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject('somewhere-else'),
      extraOverrides: [
        ...stores.overrides,
        drawerEntriesProvider.overrideWithValue([LocalProjectEntry(project)]),
      ],
    );
    Widget app(List<Widget> children) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: container.read(rootNavigatorKeyProvider),
        home: Column(children: children),
      ),
    );

    await tester.pumpWidget(app(const [Text('toast anchor')]));
    final toastContext = tester.element(find.text('toast anchor'));
    // The Navigator carries the key across this rebuild; only the anchor goes.
    await tester.pumpWidget(app(const []));
    expect(toastContext.mounted, isFalse);

    final applied = await applyNotificationRoute(
      toastContext,
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
      ),
    );

    expect(applied, isTrue);
    expect(
      container.read(selectedTargetProvider),
      const LocalProject(_projectId),
    );
  });

  test('the same sourceMessageId applies once', () async {
    final container = _container(
      sessions: [_entry(_sessionId), _entry('later')],
      focused: const LocalProject(_projectId),
    );
    const first = NotificationRoute(
      registrationId: _projectId,
      terminalId: _sessionId,
      sourceMessageId: 'msg-1',
    );
    // Same id, different session: the second delivery of one notification, not
    // a second notification.
    const second = NotificationRoute(
      registrationId: _projectId,
      terminalId: 'later',
      sourceMessageId: 'msg-1',
    );

    expect(await applyNotificationRoute(null, container, first), isTrue);
    expect(await applyNotificationRoute(null, container, second), isFalse);
    expect(container.read(activeSessionIdProvider), _sessionId);
  });

  // `sourceMessageId` is nullable by design, and the two iOS cold-start entries
  // can both fire for one tap — so the value has to be a key of its own.
  test('an id-less route applied twice applies once', () async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject(_projectId),
    );
    const route = NotificationRoute(
      registrationId: _projectId,
      terminalId: _sessionId,
    );

    expect(await applyNotificationRoute(null, container, route), isTrue);
    expect(await applyNotificationRoute(null, container, route), isFalse);
  });

  // Dedup is per container, not per route shape: a genuinely different
  // notification about the same session still lands.
  test('a different route is not swallowed by the dedup', () async {
    final container = _container(
      sessions: [_entry(_sessionId), _entry('later')],
      focused: const LocalProject(_projectId),
    );

    expect(
      await applyNotificationRoute(
        null,
        container,
        const NotificationRoute(
          registrationId: _projectId,
          terminalId: _sessionId,
        ),
      ),
      isTrue,
    );
    expect(
      await applyNotificationRoute(
        null,
        container,
        const NotificationRoute(
          registrationId: _projectId,
          terminalId: 'later',
        ),
      ),
      isTrue,
    );
    expect(container.read(activeSessionIdProvider), 'later');
  });

  // The dedup only closes IDENTICAL routes. Two DIFFERENT ones overlapping is
  // the case that corrupts focus: `activateDrawerEntryById` restores a prior
  // target after its await, so the loser hands back one the winner had left.
  test('a second route while one is in flight is refused', () async {
    final container = _container(
      sessions: [_entry(_sessionId), _entry('later')],
      focused: const LocalProject(_projectId),
    );

    final first = applyNotificationRoute(
      null,
      container,
      const NotificationRoute(
        registrationId: _projectId,
        terminalId: _sessionId,
      ),
    );
    // Started before the first has resumed past its `localDeviceUuid` await.
    final second = applyNotificationRoute(
      null,
      container,
      const NotificationRoute(registrationId: _projectId, terminalId: 'later'),
    );

    expect(await first, isTrue);
    expect(await second, isFalse);
    expect(container.read(activeSessionIdProvider), _sessionId);
  });

  // Unroutable is a real answer: a pre-W1 bridge sealed no machineUuid, and a
  // projectId alone names no machine (`computeProjectId` hashes the path).
  test('a route that resolves to nothing changes no state', () async {
    final container = _container(
      sessions: [_entry(_sessionId)],
      focused: const LocalProject(_projectId),
    );

    final applied = await applyNotificationRoute(
      null,
      container,
      const NotificationRoute(projectId: _projectId, kind: 'handler'),
    );

    expect(applied, isFalse);
    expect(container.read(activeSessionIdProvider), isNull);
    expect(container.read(pendingWorkspaceViewProvider), isNull);
    expect(container.read(pendingAgentPageProvider), isNull);
  });

  // The Recent rows a terminalId is matched against hydrate asynchronously and
  // the toast outlives that, so a tap arriving early must leave the route
  // spendable — a claim burnt here makes every later press a silent no-op.
  test('a route unroutable before the rows land can be applied again', () async {
    var rows = <RecentSessionRow>[];
    final container = ProviderContainer(
      overrides: [
        localDeviceUuidProvider.overrideWith((_) async => _localUuid),
        recentSessionsProvider.overrideWith((ref) => rows),
        freshSessionsStateProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(selectedTargetProvider.notifier)
        .set(const LocalProject(_projectId));
    const route = NotificationRoute(
      terminalId: _sessionId,
      sourceMessageId: 'msg-1',
    );

    expect(await applyNotificationRoute(null, container, route), isFalse);

    rows = [_row(_entry(_sessionId))];
    container.invalidate(recentSessionsProvider);

    expect(await applyNotificationRoute(null, container, route), isTrue);
    expect(container.read(activeSessionIdProvider), _sessionId);
  });
}
