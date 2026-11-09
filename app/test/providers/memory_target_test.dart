import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/account_machines.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/memory_surface.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

const _remote = MemoryTarget.machine(machineId: 'm1');

ProviderContainer _container({
  Map<String, String> machines = const {'m1': 'Laptop', 'm2': 'Desk'},
  List<Override> extra = const [],
  bool withMachines = true,
}) {
  final registry = ProjectSessionRegistry(
    localCap: 10,
    relayCap: 30,
    onEvict: (_) async {},
  );
  final c = ProviderContainer(
    overrides: [
      if (withMachines) accountMachinesProvider.overrideWithValue(machines),
      projectSessionRegistryProvider.overrideWith(
        () => ProjectSessionRegistryController(registry),
      ),
      selectedRegistrationIdProvider.overrideWithValue('active-project'),
      eagerControlPlanesEnabledProvider.overrideWithValue(false),
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  });

  test('an explicit view wins and never builds the inventory', () {
    final c = _container(
      withMachines: false,
      extra: [
        recentAgentsProvider.overrideWith(
          () => throw StateError('recents must not be read'),
        ),
      ],
    );
    c.read(memoryViewProvider.notifier).set(MemoryView(_remote));
    expect(c.read(memoryTargetProvider), _remote);
    expect(c.exists(recentAgentsProvider), isFalse);
    expect(c.exists(accountAgentsProvider), isFalse);
    expect(c.exists(accountMachinesProvider), isFalse);
  });

  test('a selected view follows the pick', () {
    final c = _container();
    c.read(machinePickProvider.notifier).set('m2');
    expect(
      c.read(memoryTargetProvider),
      const MemoryTarget.machine(machineId: 'm2'),
    );
    c.read(machinePickProvider.notifier).set('m1');
    expect(c.read(memoryTargetProvider), _remote);
  });

  test('demo yields no target, even for an explicit remote view', () {
    final c = _container();
    c.read(memoryViewProvider.notifier).set(MemoryView(_remote));
    c.read(demoModeProvider.notifier).set(true);
    expect(c.read(memoryTargetProvider), isNull);
  });

  test('an empty machine list yields no target', () {
    final c = _container(machines: const {});
    expect(c.read(memoryTargetProvider), isNull);
  });

  group('control-plane pin', () {
    test('a selected view and a remote pick pin that machine', () {
      final c = _container(
        extra: [
          workbenchSurfaceProvider.overrideWith(
            () => ValueController(WorkbenchSurface.memory),
          ),
        ],
      );
      c.read(machinePickProvider.notifier).set('m2');
      expect(c.read(controlPlaneAliveTargetsProvider), {'m2'});
    });

    test('a phone with no machines pins nothing', () {
      final c = _container(
        machines: const {},
        extra: [
          workbenchSurfaceProvider.overrideWith(
            () => ValueController(WorkbenchSurface.memory),
          ),
        ],
      );
      expect(c.read(controlPlaneAliveTargetsProvider), isEmpty);
    });

    test('demo with an explicit remote view pins nothing', () {
      final c = _container(
        extra: [
          workbenchSurfaceProvider.overrideWith(
            () => ValueController(WorkbenchSurface.memory),
          ),
        ],
      );
      c.read(memoryViewProvider.notifier).set(MemoryView(_remote));
      c.read(demoModeProvider.notifier).set(true);
      expect(c.read(controlPlaneAliveTargetsProvider), isEmpty);
    });
  });
}
