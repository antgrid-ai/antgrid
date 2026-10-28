import 'dart:async';

import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _target = LocalProject('p');
const _remote = RemoteProject(machineUuid: 'm', projectId: 'p');

ProviderContainer _container(Future<Map<String, String?>?> Function() detect) {
  final container = ProviderContainer(
    overrides: [
      detectedToolsForProvider.overrideWith((ref, target) => detect()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A remote machine whose control plane is fed by hand, with the real
/// [detectedToolsForProvider] reading it: that provider's null answer before
/// the `agent:tools` advert is the thing under test.
ProviderContainer _remoteContainer(StreamController<ControlPlaneState> plane) {
  final container = ProviderContainer(
    overrides: [
      controlPlaneStateProvider.overrideWith((ref, uuid) => plane.stream),
    ],
  );
  addTearDown(container.dispose);
  // Not awaited: a single-subscription controller's close never completes
  // once its listener is gone.
  addTearDown(() => unawaited(plane.close()));
  return container;
}

void main() {
  test('detection that never answers throws', () async {
    final container = _container(
      () => Completer<Map<String, String?>?>().future,
    );
    await expectLater(
      handoffTargetsFor(
        container,
        _target,
        sourceTool: 'codex',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  // Reading a failed lookup as "no other agent installed" would tell the user
  // something false.
  test('a lookup that could not ask the machine throws', () async {
    final container = _container(() async => throw StateError('no host'));
    await expectLater(
      handoffTargetsFor(container, _target, sourceTool: 'codex'),
      throwsA(isA<StateError>()),
    );
  });

  test('the source alone is offered when it is all there is', () async {
    final container = _container(
      () async => const <String, String?>{'codex': 'Codex'},
    );
    final targets = await handoffTargetsFor(
      container,
      _target,
      sourceTool: 'codex',
    );
    expect(targets.map((t) => t.tool), ['codex']);
  });

  test('an uninstalled source is appended beside the detected agents', () async {
    final container = _container(
      () async => const <String, String?>{'claude-code': 'Claude Code'},
    );
    final targets = await handoffTargetsFor(
      container,
      _target,
      sourceTool: 'codex',
    );
    expect(targets.map((t) => t.tool), ['claude-code', 'codex']);
  });

  test('a remote machine is waited on until its tools advert lands', () async {
    final plane = StreamController<ControlPlaneState>();
    final container = _remoteContainer(plane);
    // Connected, projects known, tools not yet advertised: the state a fork
    // opened right after the control plane comes up reads.
    plane.add(const ControlPlaneState());
    final pending = handoffTargetsFor(container, _remote, sourceTool: 'codex');
    await Future<void>.delayed(Duration.zero);
    plane.add(
      const ControlPlaneState(
        toolsReceived: true,
        tools: [
          AdvertisedTool(tool: 'codex', label: 'Codex'),
          AdvertisedTool(tool: 'claude-code', label: 'Claude Code'),
        ],
      ),
    );
    final targets = await pending;
    expect(targets.map((t) => t.tool), ['codex', 'claude-code']);
  });

  // The New Session picker reads the same provider and caches its null
  // pre-advert answer; the fork's lookup must not inherit it.
  test('a null answer cached before the advert is not reused', () async {
    final plane = StreamController<ControlPlaneState>();
    final container = _remoteContainer(plane);
    container.listen(detectedToolsForProvider(_remote), (_, _) {});
    plane.add(const ControlPlaneState());
    await Future<void>.delayed(Duration.zero);
    expect(
      await container.read(detectedToolsForProvider(_remote).future),
      isNull,
    );

    final pending = handoffTargetsFor(container, _remote, sourceTool: 'codex');
    plane.add(
      const ControlPlaneState(
        toolsReceived: true,
        tools: [
          AdvertisedTool(tool: 'codex', label: 'Codex'),
          AdvertisedTool(tool: 'claude-code', label: 'Claude Code'),
        ],
      ),
    );
    final targets = await pending;
    expect(targets.map((t) => t.tool), ['codex', 'claude-code']);
  });

  // Unlike a local lookup, a remote machine's empty list arrives only after
  // its advert, so it is an answer and not a failure.
  test('a remote machine advertising no tools offers the source', () async {
    final plane = StreamController<ControlPlaneState>();
    final container = _remoteContainer(plane);
    plane.add(const ControlPlaneState(toolsReceived: true));
    final targets = await handoffTargetsFor(
      container,
      _remote,
      sourceTool: 'codex',
    );
    expect(targets.map((t) => t.tool), ['codex']);
  });

  test('a control plane that fails ends the wait at once', () async {
    final plane = StreamController<ControlPlaneState>();
    final container = _remoteContainer(plane);
    final pending = handoffTargetsFor(
      container,
      _remote,
      sourceTool: 'codex',
      timeout: const Duration(seconds: 30),
    );
    plane.addError(StateError('unreachable'));
    await expectLater(pending, throwsA(isA<StateError>()));
  });

  test('a remote machine that never advertises tools times out', () async {
    final plane = StreamController<ControlPlaneState>();
    final container = _remoteContainer(plane);
    plane.add(const ControlPlaneState());
    await expectLater(
      handoffTargetsFor(
        container,
        _remote,
        sourceTool: 'codex',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
