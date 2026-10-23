import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MachineConnectionManager manager;
  late ProjectSessionRegistry registry;
  late ProviderContainer container;

  setUp(() {
    manager = MachineConnectionManager(crypto: CryptoService());
    registry = ProjectSessionRegistry(
      localCap: 10,
      relayCap: 30,
      onEvict: (_) async {},
    );
    container = ProviderContainer(
      overrides: [
        relayConnectionManagerProvider.overrideWithValue(manager),
        projectSessionRegistryProvider.overrideWith(
          () => ProjectSessionRegistryController(registry),
        ),
        selectedTargetProvider.overrideWith(
          () => ValueController(
            const RemoteProject(machineUuid: 'M', projectId: 'b'),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await manager.disposeAll();
  });

  test('Cancel under another open project on the machine evicts only the '
      'cancelled project and keeps the machine connection', () async {
    // Never dialled, so not Connected: the case the boot panel's Cancel sees.
    final connection = manager.connectionFor('M');
    container.read(projectSessionRegistryProvider.notifier)
      ..touch('M.a', isLocal: false)
      ..touch('M.b', isLocal: false);

    container.read(machineConnectionProvider.notifier).cancelActiveAgent();
    await pumpEventQueue();

    expect(container.read(selectedTargetProvider), isNull);
    expect(registry.openProjects, ['M.a']);
    expect(
      manager.peek('M'),
      same(connection),
      reason: 'M.a still rides this connection; releasing it would strand M.a',
    );
    expect(connection.isDisposed, isFalse);
  });

  test('Cancel of the only open project on the machine releases the machine '
      'connection', () async {
    final connection = manager.connectionFor('M');
    container
        .read(projectSessionRegistryProvider.notifier)
        .touch('M.b', isLocal: false);

    container.read(machineConnectionProvider.notifier).cancelActiveAgent();
    await manager.awaitRelease('M');

    expect(container.read(selectedTargetProvider), isNull);
    expect(registry.openProjects, isEmpty);
    expect(connection.isDisposed, isTrue);
    expect(manager.peek('M'), isNull);
  });
}
