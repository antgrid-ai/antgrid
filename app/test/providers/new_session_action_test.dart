import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/new_session_start.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'M';
const _projectId = 'p1';
const _compoundId = 'M.p1';

RecentAgent _recentAgent() {
  final now = DateTime(2026, 1, 1);
  return RecentAgent(
    // Recents may carry a compound id; activation matches on the bare machine
    // prefix, so this row's baseDeviceUuid is the machine 'M'.
    agentDeviceId: '$_machineUuid.someproj',
    agentLabel: 'Remote Agent',
    agentEd25519Pubkey: '',
    relayUrl: 'wss://relay.example.test/ws',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

/// Records sends and auto-acks `project:start` by emitting a running:true advert,
/// so [awaitProjectRunning] resolves immediately — mirrors the bridge
/// re-advertising agent:projects once a project's relay slot is up.
class _AutoStartTransport extends FakeAgentTransport {
  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    await super.send(message, channel: channel);
    if (message['type'] == 'project:start') {
      emit('agent:projects', {
        'projects': [
          {'projectId': message['projectId'], 'running': true},
        ],
      });
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'selected remote branch fails when the control plane is unavailable',
    () async {
      final container = ProviderContainer(
        overrides: [
          selectedTargetProjectProvider.overrideWith(
            () => ValueController(
              const PickerProject(
                id: _compoundId,
                name: 'p1',
                detail: '',
                isLocal: false,
                machineUuid: _machineUuid,
                projectId: _projectId,
              ),
            ),
          ),
          newSessionBranchSelectionProvider.overrideWith(
            () => ValueController(
              const NewSessionBranchSelection(
                targetId: _compoundId,
                branch: 'dev',
              ),
            ),
          ),
          controlPlaneClientForProvider(
            _machineUuid,
          ).overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        startNewSession(container),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot switch branch'),
          ),
        ),
      );
      expect(container.read(newSessionStartInFlightProvider), isFalse);
    },
  );

  testWidgets(
    'drill-in activation always promotes (project:start) even when running:true, '
    'sets RemoteProject, returns compound id, uses the MACHINE control plane',
    (tester) async {
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final recent = _recentAgent();
      // `running:true` only means the host core is WARM, not relay-promoted. The
      // control-plane client records the project:start the activation must send
      // regardless, and auto-acks it so awaitProjectRunning resolves.
      final cpTransport = _AutoStartTransport();
      addTearDown(cpTransport.dispose);

      late String returnedId;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            recentAgentsProvider.overrideWith(
              () => _SeededRecentAgentsNotifier([recent]),
            ),
            // Keyed by the MACHINE uuid, never the compound target id: a
            // compound-keyed resolution would build the REAL control-plane
            // provider (and with it a real relay transport) and fail.
            controlPlaneClientForProvider(_machineUuid).overrideWith((
              ref,
            ) async {
              final c = ControlPlaneClient(transport: cpTransport);
              ref.onDispose(c.dispose);
              return c;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  return TextButton(
                    key: const Key('go'),
                    onPressed: () async {
                      returnedId = await activateTargetProjectForTest(
                        ref.container,
                        const PickerProject(
                          id: _compoundId,
                          name: 'p1',
                          detail: '',
                          isLocal: false,
                          machineUuid: _machineUuid,
                          projectId: _projectId,
                          running: true,
                        ),
                      );
                    },
                    child: const Text('go'),
                  );
                },
              ),
            ),
          ),
        ),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('go'))),
      );
      // Force-create the control-plane client and seed running:true so the
      // activation's awaitProjectRunning resolves immediately (the bridge would
      // re-advertise this once the slot is up). The activation must STILL send
      // project:start first — that's the regression asserted below.
      await container.read(controlPlaneClientForProvider(_machineUuid).future);
      cpTransport.emit('agent:projects', {
        'projects': [
          {'projectId': _projectId, 'running': true},
        ],
      });
      await tester.pump();

      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();

      // 1. Selected target is the typed per-project RemoteProject.
      expect(
        container.read(selectedTargetProvider),
        const RemoteProject(machineUuid: _machineUuid, projectId: _projectId),
      );
      // 2. Returned id is the compound registrationId.
      expect(returnedId, _compoundId);
      // 3. Regression: activation ALWAYS sends project:start to promote the relay
      // slot, even though the project advertised running:true (warm ≠ promoted).
      // Skipping it here is what left the phone dialing an empty data-plane slot
      // and looping AGENT_OFFLINE.
      expect(
        cpTransport.sent.where((m) => m['type'] == 'project:start'),
        isNotEmpty,
      );
    },
  );

  group('awaitProjectRunning', () {
    test('running:true advertisement → completes true', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      final fut = awaitProjectRunning(
        client,
        'p1',
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(Duration.zero); // let the listener subscribe
      t.emit('agent:projects', {
        'projects': [
          {'projectId': 'p1', 'running': true},
        ],
      });
      expect(await fut, isTrue);
      await client.dispose();
    });

    test(
      'already running in currentState → returns true immediately',
      () async {
        final t = FakeAgentTransport();
        final client = ControlPlaneClient(transport: t);
        t.emit('agent:projects', {
          'projects': [
            {'projectId': 'p1', 'running': true},
          ],
        });
        expect(
          await awaitProjectRunning(
            client,
            'p1',
            timeout: const Duration(seconds: 2),
          ),
          isTrue,
        );
        await client.dispose();
      },
    );

    test('error envelope → completes false (no throw)', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      final fut = awaitProjectRunning(
        client,
        'p1',
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(Duration.zero);
      t.emitJson({
        'ok': false,
        'error': {'code': 'NOT_ALLOWED', 'message': 'no'},
      });
      expect(await fut, isFalse);
      await client.dispose();
    });

    test('timeout with no advertisement → completes false', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      expect(
        await awaitProjectRunning(
          client,
          'p1',
          timeout: const Duration(milliseconds: 100),
        ),
        isFalse,
      );
      await client.dispose();
    });
  });

  group('throwProjectStartFailure', () {
    test('legacy relay SESSION_LIMIT_EXCEEDED → SessionLimitExceededException, '
        'surfaced with the legacy-relay copy', () {
      expect(
        () => throwProjectStartFailure(
          'p1',
          'M',
          const ControlPlaneError(
            code: 'SESSION_LIMIT_EXCEEDED',
            message: 'Concurrent remote agent limit reached (0).',
          ),
        ),
        throwsA(
          isA<SessionLimitExceededException>()
              .having((e) => e.message, 'message', contains('limit reached'))
              // The relay's own string names a cap that no longer exists, so
              // the UI must never render it verbatim.
              .having(
                (e) => e.userMessage,
                'userMessage',
                contains('older relay'),
              ),
        ),
      );
    });

    test('any other control-plane error → generic StateError', () {
      expect(
        () => throwProjectStartFailure(
          'p1',
          'M',
          const ControlPlaneError(code: 'NOT_ALLOWED', message: 'no'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('no error (timeout) → generic StateError', () {
      expect(
        () => throwProjectStartFailure('p1', 'M', null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('start progress', () {
    const localTarget = PickerProject(
      id: _projectId,
      name: 'p1',
      detail: '/tmp/p1',
      isLocal: true,
    );

    /// One local start, wired end to end: a real [ProjectSession] over a fake
    /// transport, and a [SessionsService] whose two wire calls are answered
    /// locally. Everything else is the production [startNewSession].
    Future<_Harness> harness({
      Future<void> Function(ProviderContainer container)? onCreate,
      Future<void> Function(ProviderContainer container)? onStart,
      Future<void> Function(ProviderContainer container)? onPrepare,
    }) async {
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final transport = FakeAgentTransport();
      addTearDown(transport.dispose);
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: transport.dispose,
      );
      addTearDown(session.close);

      late ProviderContainer container;
      final service = _StubSessionsService(
        session,
        cache,
        onCreate: () async => onCreate?.call(container),
        onStart: () async => onStart?.call(container),
      );

      container = ProviderContainer(
        overrides: [
          ...stores.overrides,
          selectedTargetProjectProvider.overrideWith(
            () => ValueController(localTarget),
          ),
          // Reading this resolves through the host controller, which would
          // spawn a real bridge just to answer a label question.
          newSessionChatCapableToolsProvider.overrideWith((ref) async => null),
          projectSessionFactoryProvider.overrideWithValue((
            Ref ref,
            String projectId,
          ) async {
            await onPrepare?.call(container);
            return session;
          }),
          sessionsServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      final phases = <NewSessionStartPhase>[];
      container.listen(newSessionStartProgressProvider, (_, next) {
        if (next != null && (phases.isEmpty || phases.last != next.phase)) {
          phases.add(next.phase);
        }
      }, fireImmediately: true);

      return _Harness(container, service, phases);
    }

    test('walks the phases in order and disarms itself at the end', () async {
      final h = await harness();
      h.container.read(newSessionPromptProvider.notifier).set('fix the bug');
      // Send was pressed on the canvas: without this the surface defaults to
      // `workspace` and the start returns early at the walked-away guard,
      // which is a different path from the clean success this test names.
      h.container
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.newSession);

      await startNewSession(h.container);

      // `connecting` belongs to the remote activation alone, and
      // `switchingBranch` to an explicit non-isolated branch — a plain local
      // start walks the rest, in this order.
      expect(h.phases, [
        NewSessionStartPhase.activating,
        NewSessionStartPhase.preparing,
        NewSessionStartPhase.creating,
        NewSessionStartPhase.launching,
      ]);
      expect(h.service.created, 1);
      expect(h.service.started, ['s-new']);
      expect(h.container.read(newSessionStartInFlightProvider), isFalse);
      expect(h.container.read(newSessionStartAbortProvider), isNull);
      expect(h.container.read(activeSessionIdProvider), 's-new');
    });

    test(
      'Stop before session:create aborts, and says it was cancelled',
      () async {
        final h = await harness(
          onPrepare: (container) async {
            // Off the provider's synchronous build turn: Riverpod forbids a
            // provider writing to another while it is still building, and the
            // real Stop press arrives from a tap, not from this factory.
            await Future<void>.delayed(Duration.zero);
            container
                .read(newSessionStartProgressProvider.notifier)
                .requestCancel();
          },
        );

        await startNewSession(h.container);

        expect(
          h.container.read(newSessionStartAbortProvider)?.reason,
          NewSessionStartAbortReason.cancelled,
        );
        // The point of stopping early: nothing was put on the wire.
        expect(h.service.created, 0);
        expect(h.service.started, isEmpty);
        expect(h.container.read(newSessionStartInFlightProvider), isFalse);
      },
    );

    test(
      'Stop from session:create on is refused, and the start runs on',
      () async {
        var refusedCancel = false;
        final h = await harness(
          onCreate: (container) async {
            // Abandoning here would orphan a created-but-unstarted session on the
            // bridge, so the request is refused rather than deferred.
            refusedCancel = !container
                .read(newSessionStartProgressProvider.notifier)
                .requestCancel();
          },
        );
        // Send was pressed on the canvas, so the success is allowed to focus
        // the new session — without this the surface defaults to `workspace`
        // and this would be testing the walked-away path instead.
        h.container
            .read(workbenchSurfaceProvider.notifier)
            .set(WorkbenchSurface.newSession);

        await startNewSession(h.container);

        expect(refusedCancel, isTrue);
        expect(h.service.started, ['s-new']);
        expect(h.container.read(newSessionStartAbortProvider), isNull);
        expect(h.container.read(activeSessionIdProvider), 's-new');
      },
    );

    test(
      'a success while the user is elsewhere does not pull them back',
      () async {
        final h = await harness(
          onStart: (container) async {
            container
                .read(workbenchSurfaceProvider.notifier)
                .set(WorkbenchSurface.appSettings);
          },
        );
        h.container
            .read(workbenchSurfaceProvider.notifier)
            .set(WorkbenchSurface.newSession);

        await startNewSession(h.container);

        // The session was created and started, but nothing retargets the user:
        // TerminalScreen WATCHES activeSessionIdProvider, so writing it is
        // itself the yank this guard exists to prevent — the surface being left
        // alone is not enough on its own.
        expect(h.container.read(activeSessionIdProvider), isNull);
        expect(h.service.started, ['s-new']);
        expect(
          h.container.read(workbenchSurfaceProvider),
          WorkbenchSurface.appSettings,
        );
        expect(h.container.read(pendingActiveSessionIdProvider), isNull);
      },
    );

    test(
      'a project switch after session:create says the session was orphaned',
      () async {
        final h = await harness(
          onCreate: (container) async {
            container
                .read(selectedTargetProvider.notifier)
                .set(const LocalProject('other'));
          },
        );

        await startNewSession(h.container);

        // create landed and start never went out, so the generic
        // `intentChanged` copy ("nothing was created") would be a lie the user
        // cannot check against the bridge.
        expect(
          h.container.read(newSessionStartAbortProvider)?.reason,
          NewSessionStartAbortReason.abandonedAfterCreate,
        );
        expect(h.service.created, 1);
        expect(h.service.started, isEmpty);
      },
    );

    test('a success with the user still on the canvas navigates', () async {
      final h = await harness();
      h.container
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.newSession);

      await startNewSession(h.container);

      expect(
        h.container.read(workbenchSurfaceProvider),
        WorkbenchSurface.workspace,
      );
      expect(h.container.read(pendingActiveSessionIdProvider), 's-new');
    });
  });

  group('start progress controller', () {
    test('advance never rewinds a start already past that phase', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final start = container.read(newSessionStartProgressProvider.notifier);
      start.begin(
        phase: NewSessionStartPhase.activating,
        targetId: _projectId,
        targetName: 'p1',
        deviceName: '',
        agentLabel: 'Claude Code',
        isolated: false,
        title: 'fix the bug',
      );
      start.advance(NewSessionStartPhase.creating);

      start.advance(NewSessionStartPhase.connecting);

      final progress = container.read(newSessionStartProgressProvider)!;
      expect(progress.phase, NewSessionStartPhase.creating);
      // The point of the guard: a rewind past the boundary would re-offer a
      // Stop the flow can no longer honour.
      expect(progress.isCancellable, isFalse);
    });

    test('a completed checkout rides on every later abort', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final start = container.read(newSessionStartProgressProvider.notifier);
      start.begin(
        phase: NewSessionStartPhase.switchingBranch,
        targetId: _projectId,
        targetName: 'p1',
        deviceName: '',
        agentLabel: 'Claude Code',
        isolated: false,
        title: 'fix the bug',
        branch: 'feature/x',
      );
      start.markBranchSwitched('feature/x');

      start.abort(NewSessionStartAbortReason.cancelled);

      // "Start cancelled." alone would be a lie: the checkout landed on the
      // bridge and moved the tree under every session in the folder.
      final abort = container.read(newSessionStartAbortProvider)!;
      expect(abort.reason, NewSessionStartAbortReason.cancelled);
      expect(abort.branchSwitchedTo, 'feature/x');
    });

    test('the next start does not inherit the previous checkout', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final start = container.read(newSessionStartProgressProvider.notifier);
      void arm() => start.begin(
        phase: NewSessionStartPhase.activating,
        targetId: _projectId,
        targetName: 'p1',
        deviceName: '',
        agentLabel: 'Claude Code',
        isolated: false,
        title: 'fix the bug',
      );
      arm();
      start.markBranchSwitched('feature/x');
      start.abort(NewSessionStartAbortReason.cancelled);
      start.end();

      arm();
      start.abort(NewSessionStartAbortReason.cancelled);

      expect(
        container.read(newSessionStartAbortProvider)!.branchSwitchedTo,
        isNull,
      );
    });
  });
}

class _Harness {
  _Harness(this.container, this.service, this.phases);

  final ProviderContainer container;
  final _StubSessionsService service;
  final List<NewSessionStartPhase> phases;
}

/// Answers `session:create` / `session:start` in process, and gives a test a
/// hook that runs INSIDE each call — the only place from which the cancel
/// boundary can be probed while the start is genuinely at that stage.
class _StubSessionsService extends SessionsService {
  _StubSessionsService(
    super.session,
    CachedSessionsStore cache, {
    required this.onCreate,
    required this.onStart,
  }) : super.fromSession(cache: cache);

  final Future<void> Function() onCreate;
  final Future<void> Function() onStart;

  int created = 0;
  final started = <String>[];

  @override
  Future<SessionEntry?> create({
    String? name,
    String? tool,
    String? command,
    String? args,
    String? mode,
    String isolation = 'shared',
    String? baseBranch,
  }) async {
    await onCreate();
    created++;
    return _entry('s-new');
  }

  @override
  Future<SessionEntry?> start(
    String id, {
    String? initialPrompt,
    bool raiseRefusal = false,
  }) async {
    await onStart();
    started.add(id);
    return _entry(id);
  }

  static SessionEntry _entry(String id) => SessionEntry(
    id: id,
    name: 'fix the bug',
    createdAt: 0,
    lastUsedAt: 0,
    archived: false,
    running: true,
  );
}

class _SeededRecentAgentsNotifier extends RecentAgentsNotifier {
  _SeededRecentAgentsNotifier(this._seed);
  final List<RecentAgent> _seed;
  @override
  List<RecentAgent> build() {
    super.build(); // wire the store-change subscription
    return _seed;
  }
}
