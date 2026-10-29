import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/widgets/memory/memory_record_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const remote = MemoryTarget.machine(machineId: 'remote', label: 'Remote');
const otherRemote = MemoryTarget.machine(machineId: 'other', label: 'Other');
const local = MemoryTarget.machine();
const project = MemoryTarget.project('active-project');

final _record = <String, dynamic>{
  'id': 'memory-1',
  'content': 'A retained finding',
  'memory_type': 'note',
  'scope': 'project',
  'project_id': 'antgrid',
  'evidence': <String>[],
  'source': {'actor': 'app'},
  'lifecycle': 'active',
  'created_at': 1,
  'updated_at': 1,
};

Future<Map<String, dynamic>> _request(Map<String, dynamic> request) async =>
    switch (request['op']) {
      'status' => {
        'available': true,
        'enabled': true,
        'paused': false,
        'project_paused': false,
        'search_status': 'ready',
        'recovery_status': 'ready',
        'pending_operations': 0,
      },
      'get' => {'record': _record},
      _ => {
        'results': [_record],
        'has_more': false,
      },
    };

Future<({ProviderContainer container, BuildContext context})> _mount(
  WidgetTester tester,
) async {
  final registry = ProjectSessionRegistry(
    localCap: 10,
    relayCap: 30,
    onEvict: (_) async {},
  );
  final container = ProviderContainer(
    overrides: [
      projectSessionRegistryProvider.overrideWith(
        () => ProjectSessionRegistryController(registry),
      ),
      selectedRegistrationIdProvider.overrideWithValue('active-project'),
      workbenchSurfaceProvider.overrideWith(
        () => ValueController(WorkbenchSurface.workspace),
      ),
      eagerControlPlanesEnabledProvider.overrideWithValue(false),
      for (final target in [remote, otherRemote, local, project])
        memoryRequestProvider(target).overrideWithValue(_request),
    ],
  );
  addTearDown(container.dispose);
  late BuildContext context;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  expect(container.read(controlPlaneAliveTargetsProvider), isEmpty);
  return (container: container, context: context);
}

void main() {
  testWidgets('remote Memory pins a collapsed machine until its route ends', (
    tester,
  ) async {
    final h = await _mount(tester);
    final done = openMemoryScreen(h.context, remote);
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    await tester.pumpAndSettle();

    await tester.tap(find.text('A retained finding'));
    await tester.pumpAndSettle();
    expect(find.byType(MemoryRecordDetails), findsOneWidget);
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    Navigator.of(h.context).pop();
    await tester.pumpAndSettle();
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});

    Navigator.of(h.context).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    await tester.pumpAndSettle();
    await done;
    expect(h.container.read(controlPlaneAliveTargetsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlapping Memory routes release only their own demand', (
    tester,
  ) async {
    final h = await _mount(tester);
    final first = openMemoryScreen(h.context, remote);
    await tester.pumpAndSettle();
    final second = openMemoryScreen(h.context, remote);
    await tester.pumpAndSettle();
    final third = openMemoryScreen(h.context, otherRemote);
    await tester.pumpAndSettle();
    expect(h.container.read(controlPlaneAliveTargetsProvider), {
      'remote',
      'other',
    });

    Navigator.of(h.context).pop();
    await tester.pumpAndSettle();
    await third;
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    Navigator.of(h.context).pop();
    await tester.pumpAndSettle();
    await second;
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    Navigator.of(h.context).pop();
    await tester.pumpAndSettle();
    await first;
    expect(h.container.read(controlPlaneAliveTargetsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local and project Memory do not add machine demand', (
    tester,
  ) async {
    final h = await _mount(tester);
    for (final target in [local, project]) {
      final done = openMemoryScreen(h.context, target);
      await tester.pumpAndSettle();
      expect(h.container.read(controlPlaneAliveTargetsProvider), isEmpty);
      Navigator.of(h.context).pop();
      await tester.pumpAndSettle();
      await done;
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Navigator disposal releases Memory demand without a pop', (
    tester,
  ) async {
    final h = await _mount(tester);
    final done = openMemoryScreen(h.context, remote);
    await tester.pumpAndSettle();
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.container.read(controlPlaneAliveTargetsProvider), isEmpty);
    await done;
    expect(tester.takeException(), isNull);
  });
}
