// A StreamProvider's `async*` build parked on an upstream `.future` is
// cancelled by an invalidate, but the await is not: when the upstream later
// rejects, the superseded generator rethrows into a cancelled subscription and
// the error reaches the zone as an uncaught fatal. Production saw it as
// awaitSession's 90s TimeoutException under the eager-dial kick.

import 'dart:async';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/provider_retry.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

const _uuid = 'machine-uuid';
const _projectId = '$_uuid.proj';

/// Runs [body] against a fresh container in a guarded zone and returns every
/// error that escaped to that zone.
Future<List<Object>> _uncaught(
  List<Override> overrides,
  Future<void> Function(ProviderContainer c) body,
) async {
  final escaped = <Object>[];
  await runZonedGuarded(() async {
    final c = ProviderContainer(retry: noProviderRetry, overrides: overrides);
    try {
      await body(c);
    } finally {
      c.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }, (e, _) => escaped.add(e));
  return escaped;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  group('controlPlaneStateProvider', () {
    // Every build rejects after a beat, as an unreachable machine's dial does.
    final failingClient = controlPlaneClientForProvider.overrideWith((
      ref,
      uuid,
    ) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      throw TimeoutException('session never came up');
    });

    test('a superseded build swallows its rejected dial', () async {
      final escaped = await _uncaught([failingClient], (c) async {
        c.listen(controlPlaneStateProvider(_uuid), (_, _) {});
        await Future<void>.delayed(const Duration(milliseconds: 5));
        c.invalidate(controlPlaneStateProvider(_uuid));
        await _settle();
      });
      expect(escaped, isEmpty);
    });

    test('the live build still surfaces the rejection', () async {
      late AsyncValue<ControlPlaneState> last;
      final escaped = await _uncaught([failingClient], (c) async {
        c.listen(
          controlPlaneStateProvider(_uuid),
          (_, next) => last = next,
          fireImmediately: true,
        );
        await _settle();
      });
      expect(escaped, isEmpty);
      expect(last.error, isA<TimeoutException>());
    });
  });

  group('projectStatusProvider', () {
    final warm = projectSessionRegistryProvider.overrideWith(
      () => ProjectSessionRegistryController(
        ProjectSessionRegistry(
          localCap: 10,
          relayCap: 30,
          onEvict: (_) async {},
        )..touch(_projectId, isLocal: false),
      ),
    );

    test('a superseded build swallows its rejected session', () async {
      final escaped = await _uncaught(
        [
          warm,
          projectSessionProvider.overrideWith((ref, id) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            throw TimeoutException('session never came up');
          }),
        ],
        (c) async {
          c.listen(projectStatusProvider(_projectId), (_, _) {});
          await Future<void>.delayed(const Duration(milliseconds: 5));
          c.invalidate(projectStatusProvider(_projectId));
          await _settle();
        },
      );
      expect(escaped, isEmpty);
    });

    test('a superseded build ignores a session that resolves late', () async {
      final resolved = await newFakeProjectSession(
        FakeAgentTransport(),
        projectId: _projectId,
      );
      addTearDown(resolved.close);
      final session = Completer<ProjectSession>();
      final escaped = await _uncaught(
        [warm, projectSessionProvider.overrideWith((ref, id) => session.future)],
        (c) async {
          c.listen(projectStatusProvider(_projectId), (_, _) {});
          await Future<void>.delayed(const Duration(milliseconds: 5));
          c.invalidate(projectStatusProvider(_projectId));
          await Future<void>.delayed(const Duration(milliseconds: 5));
          // The superseded build resumes on a disposed ref, where registering
          // its teardown would throw.
          session.complete(resolved);
          await _settle();
        },
      );
      expect(escaped, isEmpty);
    });
  });
}

