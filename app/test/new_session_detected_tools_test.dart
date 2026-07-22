import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

void main() {
  test('remote target tools come from the control-plane state', () async {
    const uuid = 'dev-uuid';
    final container = ProviderContainer(overrides: [
      controlPlaneStateProvider(uuid).overrideWith(
        (ref) => Stream.value(const ControlPlaneState(tools: [
          AdvertisedTool(tool: 'codex', path: '/usr/bin/codex'),
        ])),
      ),
    ]);
    addTearDown(container.dispose);

    container.read(selectedTargetProjectProvider.notifier).set(
      const PickerProject(id: uuid, name: 'dev', detail: '', isLocal: false),
    );

    // Keep the control-plane stream provider alive and let its first value land
    // so the FutureProvider recomputes off the populated state.
    container.listen(controlPlaneStateProvider(uuid), (_, _) {});
    await container.read(controlPlaneStateProvider(uuid).future);

    final tools = await container.read(newSessionDetectedToolsProvider.future);
    expect(tools, {'codex'});
  });
}
