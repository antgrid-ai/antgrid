import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/project_catalog.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/project_index.dart';
import 'package:antgrid/providers/project_panel.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('projectSummaryLine', () {
    test('names machines, running, needs you and what the scope hides', () {
      final v = view(
        [a, b],
        [machine('mbp'), machine('stu')],
        [row(a, 'run'), row(a, 'ask'), row(b, 'done')],
        statuses: {
          'run': AgentWorkStatus.working,
          'ask': AgentWorkStatus.attention,
        },
        scope: {'mbp'},
      );
      expect(
        projectSummaryLine(v),
        'On 1 machine · 1 running · 1 needs you · 1 hidden by scope',
      );
    });
  });

  group('groupProjectSessions', () {
    final rows = [
      row(a, 'done', lastUsedAt: 30, tool: 'codex'),
      row(b, 'ask', lastUsedAt: 20),
      row(a, 'run', lastUsedAt: 10),
    ];
    final statuses = {
      'ask': AgentWorkStatus.error,
      'run': AgentWorkStatus.working,
    };
    AgentWorkStatus statusOf(RecentSessionRow r) =>
        statuses[r.session.id] ?? AgentWorkStatus.done;
    String agentOf(RecentSessionRow r) => r.session.tool ?? 'Default agent';

    test('by status: Needs you, Running, Done, whatever their age', () {
      final groups = groupProjectSessions(
        rows: rows,
        by: SessionGrouping.status,
        statusOf: statusOf,
        machines: [machine('mbp'), machine('stu')],
        agentOf: agentOf,
      );
      expect(groups.map((g) => g.label), ['Needs you', 'Running', 'Done']);
      expect(groups.first.bucket, SessionBucket.needsYou);
      expect(groups.first.rows.single.session.id, 'ask');
    });

    test('by machine: in directory order, skipping machines with nothing', () {
      final groups = groupProjectSessions(
        rows: rows,
        by: SessionGrouping.machine,
        statusOf: statusOf,
        machines: [machine('stu'), machine('idle'), machine('mbp')],
        agentOf: agentOf,
      );
      expect(groups.map((g) => g.label), ['name-stu', 'name-mbp']);
    });

    test('by agent: the most recently used agent first', () {
      final groups = groupProjectSessions(
        rows: rows,
        by: SessionGrouping.agent,
        statusOf: statusOf,
        machines: const [],
        agentOf: agentOf,
      );
      expect(groups.map((g) => g.label), ['codex', 'Default agent']);
      expect(groups.last.rows.map((r) => r.session.id), ['ask', 'run']);
    });
  });

  group('machineCardsFor', () {
    test('counts sessions and distinct isolated checkouts per machine', () {
      final v = view(
        [a, b],
        [machine('mbp'), machine('stu', online: false)],
        [
          row(a, 'one', checkoutKind: 'managed-worktree', checkoutId: 'wt-1'),
          row(a, 'two', checkoutKind: 'managed-worktree', checkoutId: 'wt-1'),
          row(a, 'three', checkoutKind: 'managed-worktree', checkoutId: 'wt-2'),
          row(a, 'main'),
          row(b, 'other'),
        ],
      );
      final cards = machineCardsFor(v);
      expect(cards.map((c) => c.machine.id), ['mbp', 'stu']);
      expect(cards.first.sessionCount, 4);
      expect(cards.first.worktreeCount, 2);
      expect(cards.last.sessionCount, 1);
      expect(cards.last.worktreeCount, 0);
    });
  });

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
}
