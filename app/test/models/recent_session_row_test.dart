import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/storage/recent_agents_store.dart';

SessionEntry s(String id, int last, {bool archived = false}) => SessionEntry(
      id: id,
      name: 'name-$id',
      createdAt: 0,
      lastUsedAt: last,
      archived: archived,
      running: false,
    );

// AbProject requires all fields; hostDeviceUuid is nullable but required.
AbProject localProject({
  required String projectId,
  String folder = '/p',
  String displayName = 'My Local',
}) => AbProject(
      projectId: projectId,
      folder: folder,
      displayName: displayName,
      hostDeviceUuid: null,
      hostMachineName: '',
      lastOpenedAt: DateTime(2026),
    );

// RecentAgent requires all fields (many required).
RecentAgent remoteAgent({
  required String agentDeviceId,
  String agentLabel = 'label',
  String? hostMachineName,
}) => RecentAgent(
      agentDeviceId: agentDeviceId,
      agentLabel: agentLabel,
      agentEd25519Pubkey: 'pk',
      relayUrl: 'ws://relay',
      phoneDeviceId: 'phone',
      phoneEd25519Pubkey: 'ppk',
      pairedAt: DateTime(2026),
      lastConnectedAt: DateTime(2026),
      hostMachineName: hostMachineName,
    );

void main() {
  test('flattens, drops archived, sorts by lastUsedAt desc', () {
    final rows = buildRecentSessions(
      cached: {
        'projLocal': [s('l1', 100), s('l2', 300, archived: true)],
        'uuidA.projRemote': [s('r1', 200)],
      },
      locals: [localProject(projectId: 'projLocal', displayName: 'My Local')],
      remotes: const [],
      inventory: const [],
      localDeviceLabel: 'This Mac',
    );
    // 200 > 100, archived l2 dropped
    expect(rows.map((r) => r.session.id).toList(), ['r1', 'l1']);
  });

  test('resolves local origin: project name + local device label', () {
    final rows = buildRecentSessions(
      cached: {'projLocal': [s('l1', 10)]},
      locals: [localProject(projectId: 'projLocal', displayName: 'My Local')],
      remotes: const [],
      inventory: const [],
      localDeviceLabel: 'This Mac',
    );
    final o = rows.single.origin;
    expect(o.isLocal, isTrue);
    expect(o.projectName, 'My Local');
    expect(o.deviceName, 'This Mac');
    expect(o.machineUuid, isNull);
    expect(o.registrationId, 'projLocal');
  });

  test('resolves remote origin via recent agent host machine name', () {
    final rows = buildRecentSessions(
      cached: {'uuidA.projRemote': [s('r1', 10)]},
      locals: const [],
      remotes: [remoteAgent(agentDeviceId: 'uuidA', hostMachineName: 'BuildBox')],
      inventory: const [],
      localDeviceLabel: 'This Mac',
    );
    final o = rows.single.origin;
    expect(o.isLocal, isFalse);
    expect(o.machineUuid, 'uuidA');
    expect(o.projectId, 'projRemote');
    expect(o.deviceName, 'BuildBox');
    expect(o.projectName, 'projRemote'); // no advert offline → projectId fallback
  });
}
