import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

void main() {
  Future<Map<String, String?>?> readTools(
    List<AdvertisedTool> advertised,
  ) async {
    const uuid = 'dev-uuid';
    final container = ProviderContainer(
      overrides: [
        controlPlaneStateProvider(uuid).overrideWith(
          (ref) => Stream.value(
            ControlPlaneState(tools: advertised, toolsReceived: true),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Keep the control-plane stream provider alive and let its first value land
    // so the FutureProvider recomputes off the populated state.
    container.listen(controlPlaneStateProvider(uuid), (_, _) {});
    await container.read(controlPlaneStateProvider(uuid).future);

    return container.read(
      detectedToolsForProvider(sessionTargetOf(_remote(uuid))).future,
    );
  }

  test('switching targets never shows the previous machine\'s tools', () async {
    final container = ProviderContainer(
      overrides: [
        controlPlaneStateProvider('a').overrideWith(
          (ref) => Stream.value(
            const ControlPlaneState(
              toolsReceived: true,
              tools: [AdvertisedTool(tool: 'codex', label: 'Codex')],
            ),
          ),
        ),
        // Machine b is still connecting: no advert yet.
        controlPlaneStateProvider(
          'b',
        ).overrideWith((ref) => const Stream<ControlPlaneState>.empty()),
      ],
    );
    addTearDown(container.dispose);
    final seen = <Map<String, String?>?>[];
    container.listen(
      newSessionDetectedToolsProvider,
      (_, next) => seen.add(next.value),
      fireImmediately: true,
    );

    container.read(selectedTargetProjectProvider.notifier).set(_remote('a'));
    await container.read(controlPlaneStateProvider('a').future);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(newSessionDetectedToolsProvider).value, {
      'codex': 'Codex',
    });

    seen.clear();
    container.read(selectedTargetProjectProvider.notifier).set(_remote('b'));
    await Future<void>.delayed(Duration.zero);
    expect(seen, isNotEmpty);
    expect(seen, everyElement(isNull));
  });

  // Riverpod keeps the last map beside an error; a machine that dropped off
  // is no longer vouching for it.
  test('a machine that drops off stops offering its last list', () async {
    final plane = StreamController<ControlPlaneState>();
    addTearDown(() => unawaited(plane.close()));
    final container = ProviderContainer(
      overrides: [
        controlPlaneStateProvider('a').overrideWith((ref) => plane.stream),
      ],
    );
    addTearDown(container.dispose);
    container.listen(newSessionDetectedToolsProvider, (_, _) {});
    container.read(selectedTargetProjectProvider.notifier).set(_remote('a'));

    plane.add(
      const ControlPlaneState(
        toolsReceived: true,
        tools: [AdvertisedTool(tool: 'codex', label: 'Codex')],
      ),
    );
    await pumpEventQueue();
    expect(container.read(newSessionDetectedToolsProvider).value, isNotNull);

    plane.addError(StateError('unreachable'));
    await pumpEventQueue();
    final tools = container.read(newSessionDetectedToolsProvider);
    expect(tools.hasError, isTrue);
    expect(tools.value, isNull);
  });

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

PickerProject _remote(String uuid) =>
    PickerProject(id: uuid, name: uuid, detail: '', isLocal: false);
