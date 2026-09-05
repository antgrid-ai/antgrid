import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/session_members.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';

import '../helpers/prefs_test_mock.dart';

const _kLocal = 'local-machine-uuid';
const _kPeer = 'peer-machine-uuid-long-enough';

SessionMemberRef _ref({
  required String machineId,
  String projectId = 'proj',
  String sessionId = 'sess',
  String? machineLabel,
  String? sessionName,
}) => SessionMemberRef(
  machineId: machineId,
  projectId: projectId,
  sessionId: sessionId,
  machineLabel: machineLabel,
  sessionName: sessionName,
);

SessionEntry _entry({
  String id = 'sess-lead',
  List<SessionMember> members = const [],
  SessionMemberOf? memberOf,
}) => SessionEntry(
  id: id,
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  members: members,
  memberOf: memberOf,
);

ProviderContainer _container({
  SessionTarget? target,
  SessionEntry? session,
  String? localUuid = _kLocal,
  List<InventoryAgent> inventory = const [],
  List<RecentAgent> recents = const [],
}) {
  useInMemoryPrefs();
  final c = ProviderContainer(
    overrides: [
      selectedTargetProvider.overrideWith(
        () => ValueController<SessionTarget?>(target),
      ),
      activeSessionOrCachedProvider.overrideWithValue(session),
      localDeviceUuidProvider.overrideWith((ref) => localUuid),
      accountAgentsProvider.overrideWith((ref) => inventory),
      recentAgentsProvider.overrideWith(() => _Recents(recents)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// The store behind [recentAgentsProvider] is opened in `main()` and injected,
/// so a container that never ran it has to stand the list up directly.
class _Recents extends RecentAgentsNotifier {
  _Recents(this._rows);
  final List<RecentAgent> _rows;

  @override
  List<RecentAgent> build() => _rows;
}

void main() {
  group('memberRegistrationId', () {
    // A member ref names a machine and a project; the app names a LOCAL project
    // by its bare id, so the same ref addresses differently depending on where
    // the app reading it runs.
    test('resolves this machine to a bare project id', () {
      expect(
        memberRegistrationId(
          _ref(machineId: _kLocal, projectId: 'proj'),
          localMachineId: _kLocal,
        ),
        'proj',
      );
    });

    test('resolves another machine to a compound id', () {
      expect(
        memberRegistrationId(
          _ref(machineId: _kPeer, projectId: 'proj'),
          localMachineId: _kLocal,
        ),
        '$_kPeer.proj',
      );
    });

    // Mobile has no local host at all, and on desktop the keychain read can
    // still be in flight. Everything is remote there, which is correct on
    // mobile and self-corrects on desktop.
    test('resolves everything as remote with no local machine id', () {
      expect(
        memberRegistrationId(
          _ref(machineId: _kLocal, projectId: 'proj'),
          localMachineId: null,
        ),
        '$_kLocal.proj',
      );
    });
  });

  group('viewedSessionRefProvider', () {
    test('is null with nothing focused', () {
      final c = _container();
      expect(c.read(viewedSessionRefProvider), isNull);
    });

    test('names this machine for a local target', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(id: 'sess-a'),
      );
      final self = c.read(viewedSessionRefProvider);
      expect(self?.machineId, _kLocal);
      expect(self?.projectId, 'proj');
      expect(self?.sessionId, 'sess-a');
    });

    test('names the remote machine for a remote target', () {
      final c = _container(
        target: const RemoteProject(machineUuid: _kPeer, projectId: 'proj'),
        session: _entry(id: 'sess-b'),
      );
      expect(c.read(viewedSessionRefProvider)?.machineId, _kPeer);
    });
  });

  group('visibleMemberTabsProvider', () {
    test('is empty for a session working alone', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(),
      );
      expect(c.read(visibleMemberTabsProvider), isEmpty);
    });

    test('puts the lead first, then its active members', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          id: 'sess-lead',
          members: [
            SessionMember(
              ref: _ref(machineId: _kPeer, sessionId: 'sess-peer'),
              joinedAt: 1,
            ),
          ],
        ),
      );
      final tabs = c.read(visibleMemberTabsProvider);
      expect(tabs.map((t) => t.sessionId), ['sess-lead', 'sess-peer']);
    });

    // A released member is the record of one that WAS in the session; a tab for
    // it would offer to take the user to a machine no longer in the group.
    test('drops released members, and the strip with the last of them', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          members: [
            SessionMember(
              ref: _ref(machineId: _kPeer, sessionId: 'sess-peer'),
              joinedAt: 1,
              state: 'released',
            ),
          ],
        ),
      );
      expect(c.read(visibleMemberTabsProvider), isEmpty);
    });

    // §7.5: the peer's own project shows the WHOLE session, so the same strip
    // renders from either end rather than leaving a peer row unexplained.
    test('a peer sees its lead first and itself second', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          id: 'sess-peer',
          memberOf: SessionMemberOf(
            ref: _ref(machineId: _kPeer, sessionId: 'sess-lead'),
            joinedAt: 1,
          ),
        ),
      );
      final tabs = c.read(visibleMemberTabsProvider);
      expect(tabs.map((t) => t.sessionId), ['sess-lead', 'sess-peer']);
    });

    // An absence is not a verdict (D11): the session is still a member of one,
    // and the tab is how the user gets back to the lead when it answers again.
    test('an orphaned membership still renders its strip', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          id: 'sess-peer',
          memberOf: SessionMemberOf(
            ref: _ref(machineId: _kPeer, sessionId: 'sess-lead'),
            joinedAt: 1,
            state: 'orphaned',
          ),
        ),
      );
      expect(c.read(visibleMemberTabsProvider), hasLength(2));
    });
  });

  group('memberViewProvider', () {
    test('is null for a session working alone', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(),
      );
      expect(c.read(memberViewProvider), isNull);
    });

    // Nothing is "selected" on the lead's own tab — the field answers "is a
    // PEER under view", which is the question the kebab's Remove item asks.
    test('a lead under view selects nothing and leads itself', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          id: 'sess-lead',
          members: [
            SessionMember(
              ref: _ref(machineId: _kPeer, sessionId: 'sess-peer'),
              joinedAt: 1,
            ),
          ],
        ),
      );
      final view = c.read(memberViewProvider);
      expect(view?.selected, isNull);
      expect(view?.leadRegistrationId, 'proj');
      expect(view?.leadSessionId, 'sess-lead');
    });

    test('a peer under view selects itself and addresses its lead', () {
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          id: 'sess-peer',
          memberOf: SessionMemberOf(
            ref: _ref(machineId: _kPeer, sessionId: 'sess-lead'),
            joinedAt: 1,
          ),
        ),
      );
      final view = c.read(memberViewProvider);
      expect(view?.selected?.sessionId, 'sess-peer');
      expect(view?.leadRegistrationId, '$_kPeer.proj');
      expect(view?.leadSessionId, 'sess-lead');
    });

    // The state DERIVES, so a navigation that never went through a tab press —
    // a drawer row, the Recent list, a notification tap — cannot leave a stale
    // selection disagreeing with what is on screen.
    test('an optimistic select is replaced by what the session says', () {
      final peer = _ref(machineId: _kPeer, sessionId: 'sess-peer');
      final c = _container(
        target: const LocalProject('proj'),
        session: _entry(
          id: 'sess-lead',
          members: [SessionMember(ref: peer, joinedAt: 1)],
        ),
      );
      c.read(memberViewProvider.notifier).select(peer);
      expect(c.read(memberViewProvider)?.selected, peer);

      c.invalidate(memberViewProvider);
      expect(c.read(memberViewProvider)?.selected, isNull);
    });
  });

  group('memberMachineLabelProvider', () {
    // What the carrier recorded at join time is the only name a row served from
    // the persisted cache can have for a machine this app never dialled.
    test('prefers the label carried on the wire', () {
      final c = _container();
      expect(
        c.read(
          memberMachineLabelProvider(
            _ref(machineId: _kPeer, machineLabel: 'Studio'),
          ),
        ),
        'Studio',
      );
    });

    test('falls back to the account inventory name', () {
      final c = _container(
        inventory: [
          InventoryAgent(
            deviceUuid: _kPeer,
            displayName: 'ignored',
            platform: 'macos',
            ed25519Pub: 'k',
            machineName: 'Studio',
          ),
        ],
      );
      expect(
        c.read(memberMachineLabelProvider(_ref(machineId: _kPeer))),
        'Studio',
      );
    });

    // The last local name a machine ever had: a peer this app connected to
    // once is in recents even when the account inventory read has not landed.
    test('falls back to a remembered host name', () {
      final c = _container(
        recents: [
          RecentAgent(
            agentDeviceId: _kPeer,
            agentLabel: 'ignored',
            agentEd25519Pubkey: 'k',
            relayUrl: 'wss://example.invalid',
            pairedAt: DateTime.utc(2020),
            lastConnectedAt: DateTime.utc(2020),
            hostMachineName: 'Studio',
          ),
        ],
      );
      expect(
        c.read(memberMachineLabelProvider(_ref(machineId: _kPeer))),
        'Studio',
      );
    });

    test('names this machine as such', () {
      final c = _container();
      expect(
        c.read(memberMachineLabelProvider(_ref(machineId: _kLocal))),
        'This machine',
      );
    });

    // A uuid is a poor name but a true one, and shortened it still tells two
    // unnamed machines apart — which is the whole job of a tab label.
    test('shortens an unnamed machine to its leading uuid characters', () {
      final c = _container();
      expect(
        c.read(memberMachineLabelProvider(_ref(machineId: _kPeer))),
        _kPeer.substring(0, 8),
      );
    });
  });

  // Nothing in the app dials a lead — a peer's bridge never reaches for it — so
  // a press on the lead tab from a member's tab is the ONLY thing that can ever
  // discover a lead has gone, and the only producer of the orphaned mark the
  // peer's badge renders.
  group('selectMemberTab', () {
    const peerProject = 'proj';
    const peerRegistrationId = '$_kPeer.$peerProject';
    const leadRegistrationId = 'lead-machine-uuid.leadproj';
    const leadRef = SessionMemberRef(
      machineId: 'lead-machine-uuid',
      projectId: 'leadproj',
      sessionId: 'sess-lead',
    );

    Future<
      ({
        ProviderContainer container,
        FakeAgentTransport peer,
        FakeAgentTransport lead,
      })
    >
    setUpPeer({required bool wasOrphaned, required bool leadWarm}) async {
      useInMemoryPrefs();
      final cache = await CachedSessionsStore.open();
      addTearDown(cache.close);
      final peerTransport = FakeAgentTransport();
      final leadTransport = FakeAgentTransport();
      ProjectSession session(String id, FakeAgentTransport t) {
        final s = ProjectSession(
          projectId: id,
          transport: t,
          mode: ProjectSessionMode.relay,
          cachedSessionsStore: cache,
          onClose: () async => await t.dispose(),
        );
        addTearDown(s.close);
        return s;
      }

      final peerSession = session(peerRegistrationId, peerTransport);
      final leadSession = session(leadRegistrationId, leadTransport);

      final c = ProviderContainer(
        overrides: [
          selectedTargetProvider.overrideWith(
            () => ValueController<SessionTarget?>(
              const RemoteProject(
                machineUuid: _kPeer,
                projectId: peerProject,
              ),
            ),
          ),
          activeSessionOrCachedProvider.overrideWithValue(
            _entry(
              id: 'sess-peer',
              memberOf: SessionMemberOf(
                ref: leadRef,
                joinedAt: 1,
                state: wasOrphaned ? 'orphaned' : 'active',
              ),
            ),
          ),
          localDeviceUuidProvider.overrideWith((ref) => _kLocal),
          accountAgentsProvider.overrideWith((ref) => const <InventoryAgent>[]),
          recentAgentsProvider.overrideWith(() => _Recents(const [])),
          projectSessionProvider.overrideWith((ref, id) async {
            if (id == peerRegistrationId) return peerSession;
            if (id == leadRegistrationId && leadWarm) return leadSession;
            // The lead's machine is not in the inventory either, so the open
            // this stands in for never gets far enough to need a session.
            throw StateError('no bridge in this test');
          }),
        ],
      );
      addTearDown(c.dispose);
      c
          .read(projectSessionRegistryProvider.notifier)
          .touch(peerRegistrationId, isLocal: false);
      if (leadWarm) {
        await c.read(projectSessionProvider(leadRegistrationId).future);
        c
            .read(projectSessionRegistryProvider.notifier)
            .touch(leadRegistrationId, isLocal: false);
      }
      // The strip has to be standing before the press, as it is on screen.
      expect(c.read(memberViewProvider)?.selected, isNotNull);
      return (container: c, peer: peerTransport, lead: leadTransport);
    }

    Map<String, dynamic>? orphanMark(FakeAgentTransport t) {
      final marks = t.sent
          .where((m) => m['type'] == 'session:member-orphan')
          .toList();
      return marks.isEmpty ? null : marks.last;
    }

    Future<void> answerOrphanMark(FakeAgentTransport t) async {
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final mark = orphanMark(t);
      if (mark == null) return;
      t.emit('session:result', {
        'requestId': mark['requestId'],
        'ok': true,
        'session': {
          'id': 'sess-peer',
          'name': 'Trace the leak',
          'createdAt': 1,
          'lastUsedAt': 1,
          'archived': false,
          'running': false,
        },
      });
    }

    test('marks the lead orphaned when its machine will not open', () async {
      final env = await setUpPeer(wasOrphaned: false, leadWarm: false);
      Object? thrown;
      final press = selectMemberTab(
        env.container,
        leadRef,
      ).catchError((Object e) => thrown = e);
      await answerOrphanMark(env.peer);
      await press;

      // The caller is still owed the throw — the tab did not open.
      expect(thrown, isA<StateError>());
      final mark = orphanMark(env.peer);
      expect(mark, isNotNull);
      expect(mark!['sessionId'], 'sess-peer');
      expect(mark['orphaned'], isTrue);
    });

    test('clears the mark once the lead answers again', () async {
      final env = await setUpPeer(wasOrphaned: true, leadWarm: true);
      final press = selectMemberTab(env.container, leadRef);
      await answerOrphanMark(env.peer);
      await press;

      final mark = orphanMark(env.peer);
      expect(mark, isNotNull);
      expect(mark!['orphaned'], isFalse);
    });

    // Idempotent on the bridge, but the peer is at the far end of a relay and a
    // mark that says nothing new is not worth a round trip per tab switch.
    test('says nothing when the answer has not changed', () async {
      final env = await setUpPeer(wasOrphaned: false, leadWarm: true);
      await selectMemberTab(env.container, leadRef);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(orphanMark(env.peer), isNull);
    });
  });
}
