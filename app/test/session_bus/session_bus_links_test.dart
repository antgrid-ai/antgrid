import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/session_bus/session_bus_links.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DrawerEntry _local(String id) => LocalProjectEntry(
  AbProject(
    projectId: id,
    folder: '/tmp/$id',
    displayName: id,
    hostDeviceUuid: 'm-lead',
    hostMachineName: 'lead',
    lastOpenedAt: DateTime(2026),
  ),
);

DrawerEntry _remote(String id) => RemoteAgentEntry(
  RecentAgent(
    agentDeviceId: id,
    agentLabel: id,
    agentEd25519Pubkey: 'pub',
    relayUrl: 'wss://relay.invalid',
    pairedAt: DateTime(2026),
    lastConnectedAt: DateTime(2026),
  ),
);

SessionMember _member(
  String machineId,
  String projectId,
  String sessionId, {
  String state = 'active',
}) => SessionMember(
  ref: SessionMemberRef(
    machineId: machineId,
    projectId: projectId,
    sessionId: sessionId,
  ),
  joinedAt: 1,
  state: state,
);

SessionEntry _session(
  String id, {
  List<SessionMember> members = const [],
  SessionMemberOf? memberOf,
}) => SessionEntry(
  id: id,
  name: id,
  createdAt: 1,
  lastUsedAt: 1,
  archived: false,
  running: true,
  members: members,
  memberOf: memberOf,
);

ProviderContainer _container({
  required List<DrawerEntry> entries,
  required Map<String, List<SessionEntry>> sessions,
}) {
  final c = ProviderContainer(
    overrides: [
      drawerEntriesProvider.overrideWithValue(entries),
      sessionsForEntryProvider.overrideWith(
        (ref, entryId) => sessions[entryId] ?? const <SessionEntry>[],
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('an active member of a local session becomes one link', () {
    final c = _container(
      entries: [_local('p-lead')],
      sessions: {
        'p-lead': [
          _session('s1', members: [_member('m-peer', 'p-peer', 's-peer')]),
        ],
      },
    );
    final links = c.read(sessionBusLinksProvider);
    expect(links.length, 1);
    final link = links.links.single;
    expect(link.leadProjectId, 'p-lead');
    expect(link.leadSessionId, 's1');
    expect(link.peerRegistrationId, 'm-peer.p-peer');
    expect(links.peerMachineIds, {'m-peer'});
  });

  test('a released member produces no link — this is the whole unpin', () {
    final c = _container(
      entries: [_local('p-lead')],
      sessions: {
        'p-lead': [
          _session(
            's1',
            members: [
              _member('m-peer', 'p-peer', 's-peer', state: 'released'),
              _member(
                'm-two',
                'p-two',
                's-two',
                state: 'released-delete-refused',
              ),
            ],
          ),
        ],
      },
    );
    expect(c.read(sessionBusLinksProvider), SessionBusLinks.empty);
    expect(c.read(sessionBusLinksProvider).peerMachineIds, isEmpty);
  });

  test('a remote entry is never a lead — its app carries its own bus', () {
    final c = _container(
      entries: [_remote('m-other')],
      sessions: {
        'm-other': [
          _session('s1', members: [_member('m-peer', 'p-peer', 's-peer')]),
        ],
      },
    );
    expect(c.read(sessionBusLinksProvider).isEmpty, isTrue);
  });

  test('a peer row (memberOf, no members) produces no link', () {
    final c = _container(
      entries: [_local('p-peer')],
      sessions: {
        'p-peer': [
          _session(
            's-peer',
            memberOf: const SessionMemberOf(
              ref: SessionMemberRef(
                machineId: 'm-lead',
                projectId: 'p-lead',
                sessionId: 's1',
              ),
              joinedAt: 1,
            ),
          ),
        ],
      },
    );
    expect(c.read(sessionBusLinksProvider).isEmpty, isTrue);
  });

  test('two members of one session are two links on one machine each', () {
    final c = _container(
      entries: [_local('p-lead')],
      sessions: {
        'p-lead': [
          _session(
            's1',
            members: [
              _member('m-a', 'p-a', 's-a'),
              _member('m-b', 'p-b', 's-b'),
            ],
          ),
        ],
      },
    );
    final links = c.read(sessionBusLinksProvider);
    expect(links.length, 2);
    expect(links.peerMachineIds, {'m-a', 'm-b'});
  });

  test(
    'an unchanged membership re-derives equal, so watchers do not churn',
    () {
      // The reason SessionBusLinks is a value type: this provider is rebuilt by
      // every session:updated burst, and controlPlaneAliveTargetsProvider is
      // downstream of it.
      List<SessionEntry> build() => [
        _session('s1', members: [_member('m-peer', 'p-peer', 's-peer')]),
      ];
      final a = _container(
        entries: [_local('p-lead')],
        sessions: {'p-lead': build()},
      ).read(sessionBusLinksProvider);
      final b = _container(
        entries: [_local('p-lead')],
        sessions: {'p-lead': build()},
      ).read(sessionBusLinksProvider);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(identical(a, b), isFalse);
    },
  );
}
