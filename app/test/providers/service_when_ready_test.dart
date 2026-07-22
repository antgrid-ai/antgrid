import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

// Stand-in for a per-project service façade: throws while [_facadeReady] is
// false (mirroring _ProjectSessionLoading during a project switch), returns a
// value once flipped. The point of the test is that serviceWhenReady NEVER
// reads — let alone `watch`es — this while the session is unresolved, so the
// throw can't surface as an unhandled exception.
final _facadeReady =
    NotifierProvider<ValueController<bool>, bool>(() => ValueController(false));

final _facadeProvider = Provider<String>((ref) {
  if (!ref.watch(_facadeReady)) {
    throw StateError('session still initializing');
  }
  return 'SERVICE-READY';
});

class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = serviceWhenReady(ref, _facadeProvider);
    return Text(svc ?? 'LOADING', textDirection: TextDirection.ltr);
  }
}

Future<ProjectSession> _buildFakeSession() async {
  useInMemoryPrefs();
  final t = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'test',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => t.dispose(),
  );
}

void main() {
  testWidgets(
    'serviceWhenReady shows loading while the session is unresolved (without '
    'touching the throwing façade) and recovers once it resolves',
    (tester) async {
      final session = await _buildFakeSession();
      final pending = Completer<ProjectSession>();
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedRegistrationIdProvider.overrideWithValue('test'),
            projectSessionProvider(
              'test',
            ).overrideWith((ref) => pending.future),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return const _Probe();
            },
          ),
        ),
      );
      await tester.pump();

      // Session unresolved: loading placeholder, and crucially no unhandled
      // exception even though the façade would throw — serviceWhenReady gates
      // on readiness and never reads it here.
      expect(tester.takeException(), isNull);
      expect(find.text('LOADING'), findsOneWidget);

      // Resolve the session and flip the façade to a value in lockstep, as a
      // real ProjectSession resolving would. serviceWhenReady must rebuild and
      // render the real value.
      capturedRef.read(_facadeReady.notifier).set(true);
      pending.complete(session);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('SERVICE-READY'), findsOneWidget);
      expect(find.text('LOADING'), findsNothing);
    },
  );
}
