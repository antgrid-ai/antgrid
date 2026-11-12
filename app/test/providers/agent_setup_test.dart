import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_setup.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'remote setup works before selecting a project and never scans locally',
    () async {
      var localScans = 0;
      final container = ProviderContainer(
        overrides: [
          localDetectedToolsProvider.overrideWith((_) async {
            localScans++;
            return {};
          }),
          pickerSourcesProvider.overrideWithValue(const [
            PickerSource(
              id: 'local',
              label: 'Local',
              isLocal: true,
              projects: [],
            ),
            PickerSource(
              id: 'machine:work',
              label: 'Work laptop',
              isLocal: false,
              machineUuid: 'work',
              projects: [],
            ),
          ]),
          controlPlaneStateProvider('work').overrideWith(
            (_) => Stream.value(
              const ControlPlaneState(
                toolsReceived: true,
                tools: [AdvertisedTool(tool: 'codex', label: 'Codex')],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedSourceIdProvider.notifier).set('machine:work');
      container.listen(agentSetupToolsProvider, (_, _) {});
      await container.read(controlPlaneStateProvider('work').future);
      await pumpEventQueue();
      expect(container.read(agentSetupMachineProvider).label, 'Work laptop');
      expect(container.read(agentSetupToolsProvider).value, {'codex': 'Codex'});
      expect(localScans, 0);

      container.read(selectedSourceIdProvider.notifier).set('local');
      expect(container.read(agentSetupToolsProvider).isLoading, isTrue);
      await container.read(localDetectedToolsProvider.future);
      await pumpEventQueue();
      expect(container.read(agentSetupToolsProvider).value, isEmpty);
      expect(localScans, 1);
    },
  );

  test(
    'workspace uses its focused machine, composer uses its own selection',
    () {
      final container = ProviderContainer(
        overrides: [
          pickerSourcesProvider.overrideWithValue(const [
            PickerSource(
              id: 'local',
              label: 'Local',
              isLocal: true,
              projects: [],
            ),
            PickerSource(
              id: 'machine:work',
              label: 'Work laptop',
              isLocal: false,
              machineUuid: 'work',
              projects: [],
            ),
          ]),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(selectedTargetProvider.notifier)
          .set(const RemoteProject(machineUuid: 'work', projectId: 'repo'));
      expect(container.read(agentSetupMachineProvider).uuid, 'work');
      container
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.newSession);
      expect(container.read(agentSetupMachineProvider).uuid, isNull);
    },
  );

  test(
    'empty detection keeps the known-agent pick; Custom requires a choice',
    () {
      expect(
        firstInstalledAgent({}, const KnownAgent('codex')),
        const KnownAgent('codex'),
      );
      expect(
        firstInstalledAgent({'codex': 'Codex'}, const CustomAgent()),
        const CustomAgent(),
      );
      final container = ProviderContainer(
        overrides: [
          newSessionDetectedToolsProvider.overrideWithValue(
            const AsyncData({}),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(newSessionNeedsAgentSetupProvider), isTrue);
      container.read(newSessionAgentProvider.notifier).set(const CustomAgent());
      expect(container.read(newSessionNeedsAgentSetupProvider), isTrue);
      container.read(newSessionCustomCmdProvider.notifier).set('my-agent');
      expect(container.read(newSessionNeedsAgentSetupProvider), isFalse);
    },
  );
}
