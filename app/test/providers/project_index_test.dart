import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/project_catalog.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/project_index.dart';
import 'package:flutter_test/flutter_test.dart';

AbProject local(String id, String name) => AbProject(
  projectId: id,
  folder: '/code/$name',
  displayName: name,
  hostDeviceUuid: 'this-device',
  hostMachineName: 'This machine',
  lastOpenedAt: DateTime(2026),
);

MachineInfo machine(String id, {bool online = true, bool isLocal = false}) =>
    MachineInfo(id: id, name: 'name-$id', isLocal: isLocal, online: online);

ProjectMember member(
  String machineId,
  String projectId,
  String name, {
  String? remote,
}) => ProjectMember(
  machineId: machineId,
  entryId: machineId == kLocalMachineKey ? projectId : '$machineId.$projectId',
  projectId: projectId,
  name: name,
  gitRemote: remote,
);

RecentSessionRow row(
  ProjectMember m,
  String sessionId, {
  required int lastUsedAt,
}) => RecentSessionRow(
  session: SessionEntry(
    id: sessionId,
    name: 'session $sessionId',
    createdAt: 0,
    lastUsedAt: lastUsedAt,
    archived: false,
    running: true,
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

AgentWorkStatus Function(RecentSessionRow) statuses(
  Map<String, AgentWorkStatus> bySession,
) => (r) => bySession[r.session.id] ?? AgentWorkStatus.done;

void main() {
  group('collectProjectMembers', () {
    test('a catalogued machine is described by its catalog alone', () {
      final members = collectProjectMembers(
        locals: const [],
        catalogs: {
          'mbp': const [
            CatalogProject(
              projectId: 'p1',
              label: 'antgrid',
              gitRemote: 'github.com/a/antgrid',
              gitRemoteProbed: true,
            ),
          ],
        },
        // A label for a project the machine no longer lists must not bring it
        // back: the catalog is replaced per advert precisely so forgotten
        // projects leave.
        labels: const {'mbp.p1': 'antgrid', 'mbp.gone': 'forgotten'},
        sessionOrigins: const [],
        machineIds: {'mbp'},
      );
      expect(members.map((m) => m.entryId), ['mbp.p1']);
      expect(members.single.gitRemote, 'github.com/a/antgrid');
    });

    test('an uncatalogued machine falls back to labels and cached sessions', () {
      final fromSession = row(member('stu', 'p9', 'notes'), 's1', lastUsedAt: 1);
      final members = collectProjectMembers(
        locals: const [],
        catalogs: const {},
        labels: const {'stu.p2': 'payments-api'},
        sessionOrigins: [fromSession.origin],
        machineIds: {'stu'},
      );
      expect(members.map((m) => m.entryId).toSet(), {'stu.p2', 'stu.p9'});
    });

    test('drops machines not in the directory', () {
      final members = collectProjectMembers(
        locals: [local('l1', 'antgrid')],
        catalogs: const {
          'gone': [CatalogProject(projectId: 'p1', label: 'x')],
        },
        labels: const {'gone.p2': 'y'},
        sessionOrigins: const [],
        machineIds: {'mbp'},
      );
      expect(members, isEmpty);
    });

    test('local projects take their remote from the local catalog', () {
      final members = collectProjectMembers(
        locals: [local('l1', 'antgrid')],
        catalogs: const {
          kLocalMachineKey: [
            CatalogProject(
              projectId: 'l1',
              gitRemote: 'github.com/a/antgrid',
              gitRemoteProbed: true,
            ),
          ],
        },
        labels: const {},
        sessionOrigins: const [],
        machineIds: {kLocalMachineKey},
      );
      expect(members.single.entryId, 'l1');
      expect(members.single.gitRemote, 'github.com/a/antgrid');
    });
  });

  group('groupProjects', () {
    test('merges copies of one repo across machines by remote, whatever the folder is called', () {
      final groups = groupProjects([
        member(kLocalMachineKey, 'l1', 'antgrid', remote: 'github.com/a/antgrid'),
        member('mbp', 'p1', 'antgrid-main', remote: 'github.com/a/antgrid'),
        member('stu', 'p2', 'site', remote: 'github.com/a/site'),
      ]);
      expect(groups, hasLength(2));
      final antgrid = groups.firstWhere((g) => g.key == 'git:github.com/a/antgrid');
      expect(antgrid.members.map((m) => m.machineId), [kLocalMachineKey, 'mbp']);
      expect(antgrid.name, 'antgrid');
    });

    test('a remote-less copy joins the one origin group sharing its name', () {
      final groups = groupProjects([
        member('mbp', 'p1', 'antgrid', remote: 'github.com/a/antgrid'),
        member('old', 'p7', 'Antgrid'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.members, hasLength(2));
    });

    test('a name shared by two different origins is not guessed between', () {
      final groups = groupProjects([
        member('mbp', 'p1', 'api', remote: 'github.com/a/api'),
        member('stu', 'p2', 'api', remote: 'github.com/b/api'),
        member('old', 'p3', 'api'),
      ]);
      expect(groups.map((g) => g.key).toSet(), {
        'git:github.com/a/api',
        'git:github.com/b/api',
        'name:api',
      });
    });

    test('remote-less projects merge by name, case-insensitively', () {
      final groups = groupProjects([
        member('mbp', 'p1', 'Notes'),
        member('stu', 'p2', 'notes'),
      ]);
      expect(groups.single.key, 'name:notes');
      expect(groups.single.members, hasLength(2));
    });
  });

  group('sessionBucket', () {
    test('needs you is attention and error; unread is done', () {
      expect(sessionBucket(AgentWorkStatus.attention), SessionBucket.needsYou);
      expect(sessionBucket(AgentWorkStatus.error), SessionBucket.needsYou);
      expect(sessionBucket(AgentWorkStatus.working), SessionBucket.running);
      expect(sessionBucket(AgentWorkStatus.unread), SessionBucket.done);
      expect(sessionBucket(AgentWorkStatus.done), SessionBucket.done);
    });
  });

  group('buildProjectViews', () {
    final mbp = member('mbp', 'p1', 'antgrid', remote: 'r/antgrid');
    final stu = member('stu', 'p2', 'antgrid', remote: 'r/antgrid');
    final site = member('stu', 'p3', 'site', remote: 'r/site');
    final groups = groupProjects([mbp, stu, site]);
    final machines = [machine('mbp'), machine('stu')];

    test('filters copies and sessions to machines in scope', () {
      final views = buildProjectViews(
        groups: groups,
        machines: machines,
        scopedMachineIds: {'mbp'},
        sessions: [
          row(mbp, 'a', lastUsedAt: 10),
          row(stu, 'b', lastUsedAt: 20),
        ],
        statusOf: statuses(const {}),
      );
      final antgrid = views.firstWhere((v) => v.group.key == 'git:r/antgrid');
      expect(antgrid.members.map((m) => m.machineId), ['mbp']);
      expect(antgrid.sessions.map((r) => r.session.id), ['a']);
      // Sessions on hidden copies still count as the project being in use.
      expect(antgrid.hasSessionsAnywhere, isTrue);

      final siteView = views.firstWhere((v) => v.group.key == 'git:r/site');
      expect(siteView.inScope, isFalse);
      expect(siteView.hasSessionsAnywhere, isFalse);
    });

    test('a project whose only sessions are on a hidden machine is in use', () {
      final views = buildProjectViews(
        groups: groups,
        machines: machines,
        scopedMachineIds: {'mbp'},
        sessions: [row(stu, 'b', lastUsedAt: 20)],
        statusOf: statuses(const {}),
      );
      final antgrid = views.firstWhere((v) => v.group.key == 'git:r/antgrid');
      expect(antgrid.sessions, isEmpty);
      expect(antgrid.hasSessionsAnywhere, isTrue);
    });

    test('counts live and needs-you sessions, and orders projects by recency', () {
      final views = buildProjectViews(
        groups: groups,
        machines: machines,
        scopedMachineIds: {'mbp', 'stu'},
        sessions: [
          row(mbp, 'a', lastUsedAt: 10),
          row(stu, 'b', lastUsedAt: 20),
          row(stu, 'c', lastUsedAt: 5),
          row(site, 'd', lastUsedAt: 30),
        ],
        statusOf: statuses({
          'a': AgentWorkStatus.working,
          'b': AgentWorkStatus.attention,
          'c': AgentWorkStatus.error,
        }),
      );
      expect(views.map((v) => v.group.key), ['git:r/site', 'git:r/antgrid']);
      final antgrid = views.last;
      expect(antgrid.liveCount, 1);
      expect(antgrid.needsYouCount, 2);
      expect(antgrid.sessions.map((r) => r.session.id), ['b', 'a', 'c']);
    });

    test('a project whose in-scope machines are all offline is dimmed, not dropped', () {
      final views = buildProjectViews(
        groups: groupProjects([mbp]),
        machines: [machine('mbp', online: false)],
        scopedMachineIds: {'mbp'},
        sessions: const [],
        statusOf: statuses(const {}),
      );
      expect(views.single.inScope, isTrue);
      expect(views.single.allOffline, isTrue);
    });
  });

  group('buildNeedsYou', () {
    final mbp = member('mbp', 'p1', 'antgrid', remote: 'r/antgrid');
    final stu = member('stu', 'p2', 'site', remote: 'r/site');

    List<NeedsYouItem> needsYou(
      Set<String> scope,
      Map<String, AgentWorkStatus> bySession,
    ) {
      final views = buildProjectViews(
        groups: groupProjects([mbp, stu]),
        machines: [machine('mbp'), machine('stu')],
        scopedMachineIds: scope,
        sessions: [
          row(mbp, 'error-new', lastUsedAt: 50),
          row(mbp, 'ask-old', lastUsedAt: 10),
          row(stu, 'ask-new', lastUsedAt: 40),
          row(stu, 'working', lastUsedAt: 60),
        ],
        statusOf: statuses(bySession),
      );
      return buildNeedsYou(
        views: views,
        machinesById: {'mbp': machine('mbp'), 'stu': machine('stu')},
        statusOf: statuses(bySession),
      );
    }

    const all = {
      'error-new': AgentWorkStatus.error,
      'ask-old': AgentWorkStatus.attention,
      'ask-new': AgentWorkStatus.attention,
      'working': AgentWorkStatus.working,
    };

    test('questions and approvals first, then failures, newest first within each', () {
      final items = needsYou({'mbp', 'stu'}, all);
      expect(items.map((i) => i.row.session.id), ['ask-new', 'ask-old', 'error-new']);
      expect(items.first.machineName, 'name-stu');
      expect(items.first.projectName, 'site');
    });

    test('only sessions on machines in scope', () {
      final items = needsYou({'mbp'}, all);
      expect(items.map((i) => i.row.session.id), ['ask-old', 'error-new']);
    });
  });

  group('defaultComposerMachine', () {
    final a = member('mbp', 'p1', 'antgrid', remote: 'r');
    final b = member('stu', 'p2', 'antgrid', remote: 'r');

    ProjectView view(List<MachineInfo> machines, List<RecentSessionRow> rows) =>
        buildProjectViews(
          groups: groupProjects([a, b]),
          machines: machines,
          scopedMachineIds: {for (final m in machines) m.id},
          sessions: rows,
          statusOf: statuses(const {}),
        ).single;

    test('the machine of the most recent session, when online', () {
      final v = view(
        [machine('mbp'), machine('stu')],
        [row(a, 'old', lastUsedAt: 1), row(b, 'new', lastUsedAt: 9)],
      );
      expect(defaultComposerMachine(v), 'stu');
    });

    test('skips a last-used machine that is offline', () {
      final v = view(
        [machine('mbp'), machine('stu', online: false)],
        [row(a, 'old', lastUsedAt: 1), row(b, 'new', lastUsedAt: 9)],
      );
      expect(defaultComposerMachine(v), 'mbp');
    });

    test('no sessions: the first online machine holding the project', () {
      final v = view([machine('mbp', online: false), machine('stu')], const []);
      expect(defaultComposerMachine(v), 'stu');
    });

    test('nothing online: no default', () {
      final v = view(
        [machine('mbp', online: false), machine('stu', online: false)],
        const [],
      );
      expect(defaultComposerMachine(v), isNull);
    });
  });
}
