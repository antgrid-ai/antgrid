import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/control_plane_client.dart';
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
    test(
      'legacy relay SESSION_LIMIT_EXCEEDED → SessionLimitExceededException, '
      'surfaced with the legacy-relay copy',
      () {
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
      },
    );

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
