// Joining a machine to a session writes two bridges that cannot be written
// atomically, so the ORDER and the compensation are the whole contract: the
// peer's session is created first, the lead's record second, and a record that
// fails takes the session it was about with it.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/add_machine_action.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _leadId = 'lead-proj';
const _peer = RemoteProject(machineUuid: 'machine-studio', projectId: 'app');

const _leadRef = SessionMemberRef(
  machineId: 'local-uuid',
  projectId: _leadId,
  sessionId: 'sess-lead',
  machineLabel: 'This machine',
);

Map<String, dynamic> _sessionJson(String id, String name) => {
  'id': id,
  'name': name,
  'createdAt': 1,
  'lastUsedAt': 1,
  'archived': false,
  'running': false,
};

/// Yields long enough for the action's chain of awaits to reach its next send.
/// Everything under test is microtask-bound — the transports answer in memory —
/// so this is a fixed number of turns rather than a wait on wall time.
Future<void> _turn([int turns = 30]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> _lastOfType(FakeAgentTransport t, String type) =>
    t.sent.lastWhere((m) => m['type'] == type);

bool _hasType(FakeAgentTransport t, String type) =>
    t.sent.any((m) => m['type'] == type);

/// Answers the `session:start` the action sends once both bridges agree. Every
/// success path reaches it, so a test that leaves it unanswered never finishes.
void _answerStart(FakeAgentTransport peer, {bool ok = true}) {
  final start = _lastOfType(peer, 'session:start');
  peer.emit('session:result', {
    'requestId': start['requestId'],
    'ok': ok,
    if (ok) 'session': _sessionJson('sess-peer', 'app'),
    if (!ok) 'error': 'no agent binary on that machine',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  /// A container holding a live [ProjectSession] for the lead and for the peer,
  /// both already warm — a member's project is pinned warm by the carrier, so
  /// the promote round trip is not the path under test here.
  Future<
    ({
      ProviderContainer container,
      FakeAgentTransport lead,
      FakeAgentTransport peer,
    })
  >
  setUpProjects() async {
    final leadTransport = FakeAgentTransport();
    final peerTransport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    addTearDown(cache.close);

    final sessions = <String, ProjectSession>{
      _leadId: ProjectSession(
        projectId: _leadId,
        transport: leadTransport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await leadTransport.dispose(),
      ),
      _peer.registrationId: ProjectSession(
        projectId: _peer.registrationId,
        transport: peerTransport,
        mode: ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async => await peerTransport.dispose(),
      ),
    };
    for (final s in sessions.values) {
      addTearDown(s.close);
    }

    final container = ProviderContainer(
      overrides: [
        projectSessionProvider.overrideWith((ref, id) async => sessions[id]!),
        localDeviceUuidProvider.overrideWith((ref) async => 'local-uuid'),
      ],
    );
    addTearDown(container.dispose);
    for (final id in sessions.keys) {
      await container.read(projectSessionProvider(id).future);
      container
          .read(projectSessionRegistryProvider.notifier)
          .touch(id, isLocal: id == _leadId);
    }
    return (
      container: container,
      lead: leadTransport,
      peer: peerTransport,
    );
  }

  Future<AddMachineOutcome> Function() start(
    ProviderContainer container, {
    SessionMemberCard? peerCard,
  }) {
    late Future<AddMachineOutcome> future;
    future = addMachineToSession(
      container,
      leadRegistrationId: _leadId,
      leadSessionId: 'sess-lead',
      leadRef: _leadRef,
      peer: _peer,
      tool: 'claude-code',
      brief: 'Take the Windows half',
      model: 'sonnet-4-6',
      mode: 'chat',
      sessionName: 'app',
      peerMachineLabel: 'Studio',
      peerProjectLabel: 'app',
      peerCard: peerCard,
    );
    return () => future;
  }

  test('creates on the peer before recording on the lead', () async {
    final env = await setUpProjects();
    final outcome = start(env.container);
    await _turn();

    final create = _lastOfType(env.peer, 'session:create');
    // The lead cannot have been told about a member that does not exist yet.
    expect(_hasType(env.lead, 'session:member-record'), isFalse);
    expect(create['memberOf'], isNotNull);
    expect(create['brief'], 'Take the Windows half');
    expect(create['isolation'], 'shared');
    // No `model` field on the wire yet, so the flag rides the raw args string.
    expect(create['args'], '--model sonnet-4-6');

    env.peer.emit('session:result', {
      'requestId': create['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    final record = _lastOfType(env.lead, 'session:member-record');
    final member = record['member'] as Map<String, dynamic>;
    expect(member['machineId'], _peer.machineUuid);
    expect(member['projectId'], _peer.projectId);
    expect(member['sessionId'], 'sess-peer');
    expect(record['role'], 'peer');

    env.lead.emit('session:result', {
      'requestId': record['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });
    await _turn();
    _answerStart(env.peer);

    final result = await outcome();
    expect(result.ok, isTrue);
    expect(result.peer?.sessionId, 'sess-peer');
    expect(result.peer?.machineLabel, 'Studio');
  });

  test('the card and the brief both ride the record to the lead', () async {
    final env = await setUpProjects();
    final outcome = start(
      env.container,
      peerCard: SessionMemberCard(
        osName: 'linux',
        osVersion: '6.8',
        osArch: 'x64',
        repoLabel: 'app',
        repoRemote: 'github.com/acme/app',
        repoBranch: 'feature/leak',
      ),
    );
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:create')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    final record = _lastOfType(env.lead, 'session:member-record');
    // The same text the peer's own create carried. The durable brief lives on
    // the peer's disk, so this copy is the only account of the human's mandate
    // the lead's agent will ever be given.
    expect(record['brief'], 'Take the Windows half');
    final member = record['member'] as Map<String, dynamic>;
    // Nested on the wire, per SessionMemberCardSchema — a flat copy would be
    // refused by the lead bridge and the machine would never join.
    expect(member['card'], {
      'os': {'name': 'linux', 'version': '6.8', 'arch': 'x64'},
      'repo': {
        'label': 'app',
        'remote': 'github.com/acme/app',
        'branch': 'feature/leak',
      },
    });

    env.lead.emit('session:result', {
      'requestId': _lastOfType(env.lead, 'session:member-record')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });
    await _turn();
    _answerStart(env.peer);
    final result = await outcome();
    // The ref handed back is what puts the user on the new tab, so it carries
    // the card the record does rather than a second, thinner copy.
    expect(result.peer?.card?.repoBranch, 'feature/leak');
  });

  // A card is display metadata and a membership is not: a machine that could
  // not answer still joins.
  test('a machine with no card still joins', () async {
    final env = await setUpProjects();
    final outcome = start(env.container);
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:create')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    final record = _lastOfType(env.lead, 'session:member-record');
    expect(
      (record['member'] as Map<String, dynamic>).containsKey('card'),
      isFalse,
    );

    env.lead.emit('session:result', {
      'requestId': record['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });
    await _turn();
    _answerStart(env.peer);
    expect((await outcome()).ok, isTrue);
  });

  // `session:create` and `session:start` are separate verbs and create starts
  // nothing, so without this the machine joins, holds the brief the create
  // carried, and never runs: a queued delivery waits for a turn boundary a
  // stopped session never reaches.
  test("starts the peer's agent, last and with no prompt of its own", () async {
    final env = await setUpProjects();
    final outcome = start(env.container);
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:create')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    // Not before the lead agreed: the compensation above deletes a session that
    // has never run, and starting first would make that untrue.
    expect(_hasType(env.peer, 'session:start'), isFalse);

    env.lead.emit('session:result', {
      'requestId': _lastOfType(env.lead, 'session:member-record')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });
    await _turn();

    final started = _lastOfType(env.peer, 'session:start');
    expect(started['sessionId'], 'sess-peer');
    // The brief is already queued on the peer bridge, wrapped by the delivery
    // template. Repeating it here would hand the agent the human's mandate a
    // second time and unwrapped.
    expect(started.containsKey('initialPrompt'), isFalse);

    _answerStart(env.peer);
    expect((await outcome()).ok, isTrue);
  });

  test('a peer that would not start still joins, and the user is told', () async {
    final env = await setUpProjects();
    final outcome = start(env.container);
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:create')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();
    env.lead.emit('session:result', {
      'requestId': _lastOfType(env.lead, 'session:member-record')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });
    await _turn();
    _answerStart(env.peer, ok: false);

    final result = await outcome();
    // Joined, because it is: the membership landed on both bridges and the tab
    // is the user's way to start it by hand.
    expect(result.ok, isTrue);
    expect(result.error, isNull);
    expect(result.warning, contains('Studio'));
    expect(result.warning, contains('did not start'));
    expect(result.message, result.warning);
  });

  test('a refused record deletes the session it was about', () async {
    final env = await setUpProjects();
    final outcome = start(env.container);
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:create')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    env.lead.emit('session:result', {
      'requestId': _lastOfType(env.lead, 'session:member-record')['requestId'],
      'ok': false,
      'errorCode': 'MEMBER_LIMIT',
      'error': 'this session already holds as many machines as it can',
    });
    await _turn();

    // The compensation, and the reason it is safe to force: the session was
    // created seconds ago by this flow and has never run.
    final delete = _lastOfType(env.peer, 'session:delete');
    expect(delete['sessionId'], 'sess-peer');
    expect(delete['force'], isTrue);

    env.peer.emit('session:result', {
      'requestId': delete['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    // The record is withdrawn as well: a record that FAILED may still have
    // landed (a lost reply is indistinguishable from a refusal), and a
    // membership pointing at a deleted session pins the peer's project with no
    // UI able to clear it.
    final release = _lastOfType(env.lead, 'session:member-release');
    expect(release['sessionId'], 'sess-lead');
    expect((release['member'] as Map<String, dynamic>)['sessionId'], 'sess-peer');
    env.lead.emit('session:result', {
      'requestId': release['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });

    final result = await outcome();
    expect(result.ok, isFalse);
    expect(result.error, contains('Studio'));
    expect(result.error, contains('was removed'));
  });

  test('a leftover the peer would not delete is named for the user', () async {
    final env = await setUpProjects();
    final outcome = start(env.container);
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:create')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-peer', 'app'),
    });
    await _turn();

    env.lead.emit('session:result', {
      'requestId': _lastOfType(env.lead, 'session:member-record')['requestId'],
      'ok': false,
      'error': 'no',
    });
    await _turn();

    env.peer.emit('session:result', {
      'requestId': _lastOfType(env.peer, 'session:delete')['requestId'],
      'ok': false,
      'error': 'busy',
    });
    await _turn();

    env.lead.emit('session:result', {
      'requestId': _lastOfType(env.lead, 'session:member-release')['requestId'],
      'ok': true,
      'session': _sessionJson('sess-lead', 'Trace the leak'),
    });

    final result = await outcome();
    expect(result.ok, isFalse);
    // The session's own name, because cleaning it up is now the user's job.
    expect(result.error, contains('"app"'));
    expect(result.error, contains('Studio'));
  });
}
