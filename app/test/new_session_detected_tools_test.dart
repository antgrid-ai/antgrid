import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

void main() {
  Future<Map<String, String?>> readTools(
    List<AdvertisedTool> advertised,
  ) async {
    const uuid = 'dev-uuid';
    final container = ProviderContainer(
      overrides: [
        controlPlaneStateProvider(uuid).overrideWith(
          (ref) => Stream.value(ControlPlaneState(tools: advertised)),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(selectedTargetProjectProvider.notifier)
        .set(
          const PickerProject(
            id: uuid,
            name: 'dev',
            detail: '',
            isLocal: false,
          ),
        );

    // Keep the control-plane stream provider alive and let its first value land
    // so the FutureProvider recomputes off the populated state.
    container.listen(controlPlaneStateProvider(uuid), (_, _) {});
    await container.read(controlPlaneStateProvider(uuid).future);

    return container.read(newSessionDetectedToolsProvider.future);
  }

  test('remote target tools come from the control-plane state', () async {
    expect(
      await readTools(const [
        AdvertisedTool(tool: 'codex', path: '/usr/bin/codex', label: 'Codex'),
      ]),
      {'codex': 'Codex'},
    );
  });

  test(
    'a bridge predating `label` leaves it null rather than dropping the tool',
    () async {
      expect(
        await readTools(const [
          AdvertisedTool(tool: 'codex', path: '/usr/bin/codex'),
        ]),
        {'codex': null},
      );
    },
  );

  test(
    'an agent this app predates still surfaces, named by the wire',
    () async {
      final tools = await readTools(const [
        AdvertisedTool(tool: 'kilo', path: '/usr/bin/kilo', label: 'Kilo'),
      ]);
      expect(tools, {'kilo': 'Kilo'});
      expect(newSessionAgentLabel(const KnownAgent('kilo'), tools), 'Kilo');
    },
  );
}
