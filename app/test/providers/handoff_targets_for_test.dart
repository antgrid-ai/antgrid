import 'dart:async';

import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _target = LocalProject('p');

ProviderContainer _container(Future<Map<String, String?>> Function() detect) {
  final container = ProviderContainer(
    overrides: [
      detectedToolsForProvider.overrideWith((ref, target) => detect()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('detection that never answers falls back to no targets', () async {
    final container = _container(() => Completer<Map<String, String?>>().future);
    final targets = await handoffTargetsFor(
      container,
      _target,
      sourceTool: 'codex',
      timeout: const Duration(milliseconds: 20),
    );
    expect(targets, isEmpty);
  });

  test('nothing detected gives no targets', () async {
    final container = _container(() async => const <String, String?>{});
    expect(
      await handoffTargetsFor(container, _target, sourceTool: 'codex'),
      isEmpty,
    );
  });

  test('the source alone is nothing to choose between', () async {
    final container = _container(
      () async => const <String, String?>{'codex': 'Codex'},
    );
    expect(
      await handoffTargetsFor(container, _target, sourceTool: 'codex'),
      isEmpty,
    );
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
}
