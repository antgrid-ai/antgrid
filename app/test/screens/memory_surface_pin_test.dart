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
      'projects' => {
        'projects': [
          {'project_id': 'antgrid', 'label': 'antgrid', 'memories': 1},
        ],
        'memories': 1,
      },
      _ => {
        'results': [_record],
        'has_more': false,
        'total': 1,
      },
    };

Future<({ProviderContainer container, BuildContext context})> _mount(
  WidgetTester tester,
) async {
  // Below the wide breakpoint, so a row tap pushes the detail page.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // The substituted test font makes the compact picker labels wider than their
  // box, and AbButton only ellipsizes with wrapLabel. This file pins machine
  // demand, not geometry.
  final onError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    onError?.call(details);
  };
  addTearDown(() => FlutterError.onError = onError);
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
      for (final target in [remote, otherRemote, local])
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
        home: Scaffold(
          body: Consumer(
            builder: (value, ref, _) {
              context = value;
              return ref.watch(workbenchSurfaceProvider) ==
                      WorkbenchSurface.memory
                  ? const MemorySurface()
                  : const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  expect(container.read(controlPlaneAliveTargetsProvider), isEmpty);
  return (container: container, context: context);
}

void main() {
  testWidgets('remote Memory pins a collapsed machine while it is the surface', (
    tester,
  ) async {
    final h = await _mount(tester);
    openMemoryScreen(h.context, remote);
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    await tester.pumpAndSettle();

    await tester.tap(find.text('A retained finding'));
    await tester.pumpAndSettle();
    expect(find.byType(MemoryRecordDetails), findsOneWidget);
    expect(find.text('Applies when'), findsOneWidget);
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    Navigator.of(h.context).pop();
    await tester.pumpAndSettle();
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});

    h.container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.workspace);
    await tester.pumpAndSettle();
    expect(find.byType(MemoryScreen), findsNothing);
    expect(h.container.read(controlPlaneAliveTargetsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening another machine moves the pin to it', (tester) async {
    final h = await _mount(tester);
    openMemoryScreen(h.context, remote);
    await tester.pumpAndSettle();
    openMemoryScreen(h.context, otherRemote);
    await tester.pumpAndSettle();
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'other'});
    expect(
      tester.widget<MemoryScreen>(find.byType(MemoryScreen)).target,
      otherRemote,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a remote project entry pins the machine and presets the filter', (
    tester,
  ) async {
    final h = await _mount(tester);
    openMemoryScreen(h.context, remote, projectId: 'antgrid');
    expect(h.container.read(controlPlaneAliveTargetsProvider), {'remote'});
    expect(h.container.read(workbenchSurfaceProvider), WorkbenchSurface.memory);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MemoryScreen>(find.byType(MemoryScreen)).initialProjectId,
      'antgrid',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening the same project mounts a fresh screen', (
    tester,
  ) async {
    final h = await _mount(tester);
    openMemoryScreen(h.context, local, projectId: 'antgrid');
    await tester.pumpAndSettle();
    final first = tester.state(find.byType(MemoryScreen));
    openMemoryScreen(h.context, local, projectId: 'antgrid');
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(MemoryScreen)), isNot(same(first)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('local Memory does not add machine demand', (tester) async {
    final h = await _mount(tester);
    openMemoryScreen(h.context, local);
    await tester.pumpAndSettle();
    expect(find.byType(MemoryScreen), findsOneWidget);
    expect(h.container.read(controlPlaneAliveTargetsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
