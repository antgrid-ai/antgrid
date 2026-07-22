import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/util/device_id.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

void main() {
  test('one source per remote machine uuid; Local first', () {
    // Two agents share machineName 'Mac Studio' but are DISTINCT machines (their
    // bare deviceUuids differ) — so each yields its own source, no merge.
    final sources = buildPickerSources(
      localProjects: const [],
      recents: const [],
      inventory: [
        InventoryAgent(
          deviceUuid: 'a',
          displayName: 'api',
          platform: 'macos',
          ed25519Pub: 'k',
          machineName: 'Mac Studio',
        ),
        InventoryAgent(
          deviceUuid: 'b',
          displayName: 'web',
          platform: 'macos',
          ed25519Pub: 'k',
          machineName: 'Mac Studio',
        ),
        InventoryAgent(
          deviceUuid: 'c',
          displayName: 'svc',
          platform: 'linux',
          ed25519Pub: 'k',
          machineName: 'devbox',
        ),
      ],
    );
    expect(sources.first.id, 'local');
    final remote = sources.where((s) => !s.isLocal).toList();
    expect(remote.map((s) => s.machineUuid), containsAll(['a', 'b', 'c']));
    expect(remote.every((s) => s.projects.isEmpty), isTrue);
  });

  test('agents with no machineName get the Remote label', () {
    final sources = buildPickerSources(
      localProjects: const [],
      recents: const [],
      inventory: [
        InventoryAgent(
          deviceUuid: 'a',
          displayName: 'api',
          platform: 'macos',
          ed25519Pub: 'k',
          machineName: null,
        ),
      ],
    );
    expect(sources.any((s) => s.label == 'Remote'), isTrue);
  });

  test('recents not in inventory still produce a machine source', () {
    final sources = buildPickerSources(
      localProjects: const [],
      recents: [
        RecentAgent(
          agentDeviceId: 'r1',
          agentLabel: 'my-project',
          agentEd25519Pubkey: 'k',
          relayUrl: 'wss://relay',
          phoneDeviceId: 'p',
          phoneEd25519Pubkey: 'pk',
          pairedAt: DateTime(2026),
          lastConnectedAt: DateTime(2026),
          hostMachineName: 'devbox',
        ),
      ],
      inventory: const [],
    );
    final devbox = sources.firstWhere((s) => s.label == 'devbox');
    expect(devbox.machineUuid, baseDeviceUuid('r1'));
    expect(devbox.projects, isEmpty);
  });

  test('inventory agent for this device is not a remote machine source even '
      'with no local project', () {
    // The locally-spawned agent appears in the account inventory under this
    // device's own host uuid. Without a local project to dedup against it would
    // render as a phantom "RadhaAI" remote machine — localDeviceUuid suppresses
    // it. (Desktop always has the Local source.)
    final sources = buildPickerSources(
      localProjects: const [],
      recents: const [],
      inventory: [
        InventoryAgent(
          deviceUuid: 'self-uuid',
          displayName: 'RadhaAI',
          platform: 'windows',
          ed25519Pub: 'k',
          machineName: 'RadhaAI',
        ),
      ],
      localDeviceUuid: 'self-uuid',
    );
    expect(sources.map((s) => s.id), ['local']);
    expect(sources.where((s) => !s.isLocal), isEmpty);
  });

  test('inventory agent matching a local hostDeviceUuid is not duplicated as a '
      'remote row', () {
    final sources = buildPickerSources(
      localProjects: [
        AbProject(
          projectId: 'proj1',
          folder: '/home/me/proj1',
          displayName: 'proj1',
          hostDeviceUuid: 'h1',
          hostMachineName: 'devbox',
          lastOpenedAt: DateTime(2026),
        ),
      ],
      recents: const [],
      inventory: [
        InventoryAgent(
          deviceUuid: 'h1',
          displayName: 'proj1',
          platform: 'linux',
          ed25519Pub: 'k',
          machineName: 'devbox',
        ),
      ],
    );
    final remoteSources = sources.where((s) => !s.isLocal);
    expect(
      remoteSources.expand((s) => s.projects).any((p) => p.id == 'h1'),
      isFalse,
    );
  });

  test('remote PickerProject carries machineUuid + projectId + running', () {
    const p = PickerProject(
      id: 'M.proj1',
      name: 'proj1',
      detail: '/home/m/proj1',
      isLocal: false,
      machineUuid: 'M',
      projectId: 'proj1',
      running: false,
    );
    expect(p.machineUuid, 'M');
    expect(p.projectId, 'proj1');
    expect(p.running, isFalse);
    expect(
      RemoteProject(
        machineUuid: p.machineUuid!,
        projectId: p.projectId!,
      ).registrationId,
      'M.proj1',
    );
  });

  test('local PickerProject defaults: no machine/project, running true', () {
    const p = PickerProject(
      id: 'localProj',
      name: 'x',
      detail: '/x',
      isLocal: true,
    );
    expect(p.machineUuid, isNull);
    expect(p.projectId, isNull);
    expect(p.running, isTrue);
  });

  test('buildRemoteProjectRows maps advertised projects to compound rows', () {
    final rows = buildRemoteProjectRows('M', const [
      AdvertisedProject(
        projectId: 'a',
        label: 'Alpha',
        path: '/a',
        running: true,
      ),
      AdvertisedProject(projectId: 'b', path: '/b', running: false),
    ]);
    expect(rows.map((r) => r.id), ['M.a', 'M.b']);
    expect(rows[0].name, 'Alpha');
    expect(rows[0].running, isTrue);
    expect(rows[1].name, 'b'); // falls back to projectId when label null
    expect(rows[1].machineUuid, 'M');
    expect(rows[1].projectId, 'b');
    expect(rows[1].running, isFalse);

    final rowsEmptyLabel = buildRemoteProjectRows('M', const [
      AdvertisedProject(projectId: 'c', label: '', path: '/c', running: true),
    ]);
    expect(
      rowsEmptyLabel.single.name,
      'c',
    ); // empty label falls back to projectId
  });

  test('buildRemoteProjectRows on empty list returns empty', () {
    expect(buildRemoteProjectRows('M', const []), isEmpty);
  });

  test(
    'buildPickerSources emits one source per remote uuid, id machine:<uuid>, '
    'no pure project rows',
    () {
      final sources = buildPickerSources(
        localProjects: const [],
        recents: const [],
        inventory: [
          InventoryAgent(
            deviceUuid: 'u1',
            displayName: 'a1',
            platform: 'macos',
            ed25519Pub: 'k1',
            machineName: 'Alpha',
          ),
          InventoryAgent(
            deviceUuid: 'u2',
            displayName: 'a2',
            platform: 'linux',
            ed25519Pub: 'k2',
            machineName: 'Beta',
          ),
        ],
        includeLocal: false,
      );
      final remote = sources.where((s) => !s.isLocal).toList();
      expect(
        remote.map((s) => s.id),
        containsAll(['machine:u1', 'machine:u2']),
      );
      expect(remote.firstWhere((s) => s.id == 'machine:u1').machineUuid, 'u1');
      expect(remote.every((s) => s.projects.isEmpty), isTrue);
    },
  );

  test('buildPickerSources disambiguates duplicate machine labels', () {
    final sources = buildPickerSources(
      localProjects: const [],
      recents: const [],
      inventory: [
        InventoryAgent(
          deviceUuid: 'aaaaaa11',
          displayName: 'x',
          platform: 'linux',
          ed25519Pub: 'k1',
        ), // no machineName -> 'Remote'
        InventoryAgent(
          deviceUuid: 'bbbbbb22',
          displayName: 'y',
          platform: 'linux',
          ed25519Pub: 'k2',
        ), // no machineName -> 'Remote'
      ],
      includeLocal: false,
    );
    final labels = sources.where((s) => !s.isLocal).map((s) => s.label).toSet();
    expect(labels.length, 2); // two distinct tab labels, not two "Remote"
  });

  testWidgets('resetNewSessionForm clears the prompt', (tester) async {
    late WidgetRef ref;

    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    ref.read(newSessionPromptProvider.notifier).set('leftover text');
    resetNewSessionForm(ref);
    await tester.pump();

    expect(ref.read(newSessionPromptProvider), '');
  });
}
