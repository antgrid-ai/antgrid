import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/project_catalog.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/project_index.dart';
import 'package:antgrid/providers/project_composer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

MachineInfo machine(String id, {bool online = true}) =>
    MachineInfo(id: id, name: 'name-$id', isLocal: false, online: online);

ProjectMember member(String machineId, String projectId) => ProjectMember(
  machineId: machineId,
  entryId: machineId == kLocalMachineKey ? projectId : '$machineId.$projectId',
  projectId: projectId,
  name: 'antgrid',
  gitRemote: 'r/antgrid',
);

RecentSessionRow row(
  ProjectMember m,
  String id, {
  int lastUsedAt = 1,
  String? tool,
  String checkoutKind = 'main',
  String? checkoutId,
}) => RecentSessionRow(
  session: SessionEntry(
    id: id,
    name: id,
    createdAt: 0,
    lastUsedAt: lastUsedAt,
    archived: false,
    running: true,
    tool: tool,
    checkoutKind: checkoutKind,
    checkoutId: checkoutId ?? 'main',
  ),
  origin: RecentOrigin(
    isLocal: m.machineId == kLocalMachineKey,
    registrationId: m.entryId,
    projectId: m.projectId,
    machineUuid: m.machineId == kLocalMachineKey ? null : m.machineId,
    projectName: m.name,
    deviceName: 'device ${m.machineId}',
  ),
);

ProjectView view(
  List<ProjectMember> members,
  List<MachineInfo> machines,
  List<RecentSessionRow> rows, {
  Map<String, AgentWorkStatus> statuses = const {},
  Set<String>? scope,
}) => buildProjectViews(
  groups: groupProjects(members),
  machines: machines,
  scopedMachineIds: scope ?? {for (final m in machines) m.id},
  sessions: rows,
  statusOf: (r) => statuses[r.session.id] ?? AgentWorkStatus.done,
).single;

void main() {
  final a = member('mbp', 'p1');
  final b = member('stu', 'p2');

  group('pickerProjectFor', () {
    test('a local copy targets the bare project id', () {
      final t = pickerProjectFor(
        member(kLocalMachineKey, 'l1'),
        folder: '/code/antgrid',
        running: false,
      );
      expect(t.id, 'l1');
      expect(t.isLocal, isTrue);
      expect(t.detail, '/code/antgrid');
    });

    test('a remote copy targets the compound registration id', () {
      final t = pickerProjectFor(a, folder: null, running: true);
      expect(t.id, 'mbp.p1');
      expect(t.isLocal, isFalse);
      expect(t.machineUuid, 'mbp');
      expect(t.projectId, 'p1');
      expect(t.running, isTrue);
    });
  });

  group('pointComposerAtProject', () {
    late TestStoreOverrides stores;
    setUp(() async {
      useInMemoryPrefs();
      stores = await buildTestStoreOverrides();
    });
    tearDown(() => stores.close());

    test('targets the online machine its latest session ran on', () {
      final c = ProviderContainer(overrides: stores.overrides);
      addTearDown(c.dispose);
      final v = view(
        [a, b],
        [machine('mbp'), machine('stu')],
        [row(b, 'newer', lastUsedAt: 2), row(a, 'older')],
      );

      pointComposerAtProject(c, v);

      expect(c.read(selectedSourceIdProvider), 'machine:stu');
      expect(c.read(selectedTargetProjectProvider)?.id, 'stu.p2');
    });

    test('leaves the composer alone when no machine holding it is up', () {
      final c = ProviderContainer(overrides: stores.overrides);
      addTearDown(c.dispose);
      final before = c.read(selectedTargetProjectProvider);
      final v = view(
        [a],
        [machine('mbp', online: false)],
        [row(a, 'only')],
      );

      pointComposerAtProject(c, v);

      expect(c.read(selectedTargetProjectProvider), before);
    });
  });
}
