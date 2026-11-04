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
import 'package:antgrid/providers/project_composer.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/widgets/machine_scope_sheet.dart';
import 'package:antgrid/widgets/mobile/mobile_home.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

MachineInfo _machine(String id, {bool online = true, bool? remote}) =>
    MachineInfo(
      id: id,
      name: id,
      isLocal: false,
      online: online,
      remoteAccessEnabled: remote,
    );

final _onMbp = ProjectMember(
  machineId: 'mbp',
  entryId: 'mbp.p1',
  projectId: 'p1',
  name: 'antgrid',
  gitRemote: 'r/antgrid',
);
final _onStu = ProjectMember(
  machineId: 'stu',
  entryId: 'stu.p2',
  projectId: 'p2',
  name: 'antgrid',
  gitRemote: 'r/antgrid',
);

RecentSessionRow _row(ProjectMember m, String id) => RecentSessionRow(
  session: SessionEntry(
    id: id,
    name: 'Session $id',
    createdAt: 0,
    lastUsedAt: 1,
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

final _ask = _row(_onMbp, 'ask');
final _run = _row(_onStu, 'run');
const _statuses = {'ask': AgentWorkStatus.attention, 'run': AgentWorkStatus.working};

ProjectView _view() => buildProjectViews(
  groups: groupProjects([_onMbp, _onStu]),
  machines: [_machine('mbp'), _machine('stu')],
  scopedMachineIds: {'mbp', 'stu'},
  sessions: [_ask, _run],
  statusOf: (r) => _statuses[r.session.id] ?? AgentWorkStatus.done,
).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scopeCandidates', () {
    test('a phone leaves out machines whose remote access is off', () {
      final machines = [
        _machine('on', remote: true),
        _machine('off', remote: false),
        _machine('unknown'),
      ];
      expect(
        scopeCandidates(machines, mobile: true).map((m) => m.id),
        ['on', 'unknown'],
      );
      expect(scopeCandidates(machines, mobile: false), hasLength(3));
    });
  });

  late TestStoreOverrides stores;
  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });
  tearDown(() => stores.close());

  Widget host(Widget child, {List<MachineInfo>? machines}) => ProviderScope(
    overrides: [
      ...stores.overrides,
      currentUserProvider.overrideWith((_) async => null),
      projectViewsProvider.overrideWithValue([_view()]),
      needsYouProvider.overrideWithValue([
        NeedsYouItem(
          row: _ask,
          status: AgentWorkStatus.attention,
          machineName: 'mbp',
          projectName: 'antgrid',
        ),
      ]),
      machineDirectoryProvider.overrideWithValue(
        machines ?? [_machine('mbp'), _machine('stu')],
      ),
      recentSessionsProvider.overrideWithValue([_ask, _run]),
      recentSessionStatusesProvider.overrideWithValue({
        recentStatusKey(_ask.origin.registrationId, 'ask'):
            AgentWorkStatus.attention,
        recentStatusKey(_run.origin.registrationId, 'run'):
            AgentWorkStatus.working,
      }),
      machineCapabilityCardProvider('mbp').overrideWith((_) async => null),
      machineCapabilityCardProvider('stu').overrideWith((_) async => null),
    ],
    child: MaterialApp(theme: buildAbTheme(), home: Scaffold(body: child)),
  );

  testWidgets('home leads with what needs you, then the merged projects', (
    tester,
  ) async {
    await tester.pumpWidget(host(const MobileHomeList()));
    // The needs-you dot pulses for as long as it is shown, so this never
    // settles; one frame past the first build is all it needs.
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('Session ask'), findsOneWidget);
    expect(find.text('mbp · antgrid'), findsOneWidget);
    expect(find.text('Open and respond'), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('1 live'), findsOneWidget);

    final open = tester.getSize(find.text('Open and respond'));
    expect(open.height, greaterThan(0));
    final button = tester.getSize(
      find.ancestor(
        of: find.text('Open and respond'),
        matching: find.byType(ConstrainedBox),
      ).first,
    );
    expect(button.height, greaterThanOrEqualTo(44));
  });

  testWidgets('a project points the composer at it', (tester) async {
    await tester.pumpWidget(host(const MobileHomeList()));
    // The needs-you dot pulses for as long as it is shown, so this never
    // settles; one frame past the first build is all it needs.
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('antgrid'));
    await tester.pump(const Duration(milliseconds: 100));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MobileHomeList)),
    );
    expect(container.read(composerProjectViewProvider)?.group.key, 'git:r/antgrid');
  });

  testWidgets('the scope sheet locks a machine whose remote access is off', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const MachineScopeSheet(),
        machines: [_machine('mbp', remote: true), _machine('win', remote: false)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remote access is off on this machine'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('win, locked')), findsOneWidget);
  });
}
