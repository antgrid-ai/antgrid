import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/machine_capability_card.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/project_index.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/widgets/project_panel/project_panel_view.dart';
import 'package:antgrid/widgets/recent_sessions/recent_session_row_widget.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

MachineInfo _machine(String id, {bool online = true}) =>
    MachineInfo(id: id, name: id, isLocal: false, online: online);

ProjectMember _member(String machineId, String projectId) => ProjectMember(
  machineId: machineId,
  entryId: '$machineId.$projectId',
  projectId: projectId,
  name: 'antgrid',
  gitRemote: 'r/antgrid',
);

RecentSessionRow _row(ProjectMember m, String id, int lastUsedAt) =>
    RecentSessionRow(
      session: SessionEntry(
        id: id,
        name: 'Session $id',
        createdAt: 0,
        lastUsedAt: lastUsedAt,
        archived: false,
        running: true,
      ),
      origin: RecentOrigin(
        isLocal: false,
        registrationId: m.entryId,
        projectId: m.projectId,
        machineUuid: m.machineId,
        projectName: m.name,
        deviceName: m.machineId,
      ),
    );

final _onMbp = _member('mbp', 'p1');
final _onStu = _member('stu', 'p2');
final _rows = [
  _row(_onStu, 'ask', 3),
  _row(_onMbp, 'run', 2),
  _row(_onMbp, 'old', 1),
];
const _statuses = {
  'ask': AgentWorkStatus.attention,
  'run': AgentWorkStatus.working,
};

ProjectView _view({Set<String> scope = const {'mbp', 'stu'}}) =>
    buildProjectViews(
      groups: groupProjects([_onMbp, _onStu]),
      machines: [_machine('mbp'), _machine('stu')],
      scopedMachineIds: scope,
      sessions: _rows,
      statusOf: (r) => _statuses[r.session.id] ?? AgentWorkStatus.done,
    ).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;
  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });
  tearDown(() => stores.close());

  Widget host(ProjectView view) => ProviderScope(
    overrides: [
      ...stores.overrides,
      currentUserProvider.overrideWith((_) async => null),
      recentSessionStatusesProvider.overrideWithValue({
        for (final r in _rows)
          recentStatusKey(r.origin.registrationId, r.session.id):
              _statuses[r.session.id] ?? AgentWorkStatus.done,
      }),
      // A branch is an RPC to the machine; nothing here may dial one.
      machineCapabilityCardProvider('mbp').overrideWith((_) async => null),
      machineCapabilityCardProvider('stu').overrideWith((_) async => null),
    ],
    child: MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(body: ProjectPanelView(view: view)),
    ),
  );

  testWidgets('heads the panel with the project and what it is doing', (
    tester,
  ) async {
    await tester.pumpWidget(host(_view()));
    await tester.pumpAndSettle();

    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('On 2 machines · 1 running · 1 needs you'), findsOneWidget);
  });

  testWidgets('groups by status with what needs you first, and offers Respond', (
    tester,
  ) async {
    await tester.pumpWidget(host(_view()));
    await tester.pumpAndSettle();

    final needs = tester.getTopLeft(find.text('NEEDS YOU')).dy;
    final running = tester.getTopLeft(find.text('RUNNING')).dy;
    final done = tester.getTopLeft(find.text('DONE')).dy;
    expect(needs, lessThan(running));
    expect(running, lessThan(done));
    expect(find.text('Respond'), findsOneWidget);
  });

  testWidgets('a machine card narrows the list, and a second tap widens it', (
    tester,
  ) async {
    await tester.pumpWidget(host(_view()));
    await tester.pumpAndSettle();
    expect(find.byType(RecentSessionRowWidget), findsNWidgets(3));

    await tester.tap(find.text('mbp').first);
    await tester.pumpAndSettle();
    expect(find.byType(RecentSessionRowWidget), findsNWidgets(2));
    expect(find.text('Only mbp'), findsOneWidget);

    await tester.tap(find.text('mbp').first);
    await tester.pumpAndSettle();
    expect(find.byType(RecentSessionRowWidget), findsNWidgets(3));
  });

  testWidgets('can regroup by machine', (tester) async {
    await tester.pumpWidget(host(_view()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('MACHINE'));
    await tester.pumpAndSettle();
    expect(find.text('NEEDS YOU'), findsNothing);
    // Machine names head the groups (mono, uppercased).
    expect(find.text('STU'), findsOneWidget);
  });

  testWidgets('a project the scope hides says where it is, never a blank panel', (
    tester,
  ) async {
    await tester.pumpWidget(host(_view(scope: const {})));
    await tester.pumpAndSettle();

    expect(find.text('antgrid is outside your machine scope'), findsOneWidget);
    expect(find.text('It lives on mbp and stu.'), findsOneWidget);
    expect(find.text('Show all machines'), findsOneWidget);
  });
}
