import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/project_index.dart';
import 'package:antgrid/widgets/new_session/project_menu.dart';

MachineInfo _machine(String id, {bool online = true}) =>
    MachineInfo(id: id, name: id, isLocal: false, online: online);

ProjectMember _member(String machineId, String projectId, String name) =>
    ProjectMember(
      machineId: machineId,
      entryId: '$machineId.$projectId',
      projectId: projectId,
      name: name,
      gitRemote: 'r/$name',
    );

RecentSessionRow _row(ProjectMember m, String id, int lastUsedAt) =>
    RecentSessionRow(
      session: SessionEntry(
        id: id,
        name: id,
        createdAt: 0,
        lastUsedAt: lastUsedAt,
        archived: false,
        running: false,
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

/// `antgrid` on two machines, its latest session on `stu`; `notes` only on a
/// machine that is down.
List<ProjectView> _views() {
  final onMbp = _member('mbp', 'p1', 'antgrid');
  final onStu = _member('stu', 'p2', 'antgrid');
  final notes = _member('old', 'p3', 'notes');
  return buildProjectViews(
    groups: groupProjects([onMbp, onStu, notes]),
    machines: [_machine('mbp'), _machine('stu'), _machine('old', online: false)],
    scopedMachineIds: {'mbp', 'stu', 'old'},
    sessions: [_row(onMbp, 'older', 1), _row(onStu, 'newer', 2)],
    statusOf: (_) => AgentWorkStatus.done,
  );
}

Widget _host({
  List<ProjectView>? views,
  VoidCallback? onOpenFolder,
}) {
  return ProviderScope(
    overrides: [
      projectViewsProvider.overrideWithValue(views ?? _views()),
      // The chip resolves its label against the picker's sources.
      pickerSourcesProvider.overrideWithValue(const []),
    ],
    child: MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(
        body: Center(child: ProjectChip(onOpenFolder: onOpenFolder ?? () {})),
      ),
    ),
  );
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ProjectChip)));

void main() {
  testWidgets('chip shows Select project… until a target is picked', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    expect(find.text('Select project…'), findsOneWidget);
  });

  testWidgets('lists each project once, merged across machines', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();

    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('2 machines'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
  });

  testWidgets('picking a project points the composer at its last-used machine', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('antgrid'));
    await tester.pumpAndSettle();

    final c = _container(tester);
    expect(c.read(selectedTargetProjectProvider)?.id, 'stu.p2');
    expect(c.read(selectedSourceIdProvider), 'machine:stu');
    // The panel closes on a pick.
    expect(find.text('notes'), findsNothing);
  });

  testWidgets('a project whose every machine is down cannot be picked', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes'));
    await tester.pumpAndSettle();

    expect(_container(tester).read(selectedTargetProjectProvider), isNull);
  });

  testWidgets('Open folder… invokes the callback and closes the panel', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(_host(onOpenFolder: () => opened++));
    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open folder…'));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.text('antgrid'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('nothing in scope says so', (tester) async {
    await tester.pumpWidget(_host(views: const []));
    await tester.tap(find.byType(ProjectChip));
    await tester.pumpAndSettle();
    expect(find.text('No projects on the machines in scope'), findsOneWidget);
  });
}
