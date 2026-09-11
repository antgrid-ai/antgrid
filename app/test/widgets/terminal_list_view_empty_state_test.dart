// "No terminals — open a shell to interact with your project" is a claim about
// the PROJECT, and an empty list is not evidence for it while terminals are
// still being attached. These are the only guards on that copy, so a change to
// the fork that silently restores the lie fails nowhere else.
import 'dart:async';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/terminal_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// Mounts the list over a real (local) [ProjectSession] — the view resolves its
/// service through `serviceWhenReady`, which gates on a RESOLVED session and so
/// cannot be satisfied by a stubbed façade alone — with the terminal state
/// pinned to [attach] and no ad-hoc tabs.
Future<ProjectSession> _pumpEmptyList(
  WidgetTester tester,
  CheckoutAttachStatus attach,
) async {
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'test',
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
  // Not awaited, for the reason `test_store_overrides.dart` records: close()
  // flushes CachedSessionsStore through SharedPreferencesAsync, and awaiting
  // real I/O inside testWidgets' fake-async zone wedges teardown with no
  // timeout. The synchronous part — marking controllers closed, cancelling the
  // pending flush — is all that has to happen before the next test.
  addTearDown(() => unawaited(session.close()));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
        terminalStateProvider.overrideWith(
          (ref) => Stream.value(TerminalState(attach: attach)),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: TerminalListView())),
    ),
  );
  await tester.pump();
  await tester.pump();
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalListView empty state', () {
    testWidgets('says nothing about there being no terminals while the '
        'checkout is still attaching', (tester) async {
      await _pumpEmptyList(
        tester,
        CheckoutAttachStatus.attaching,
      );

      expect(find.text('attaching terminals…'), findsOneWidget);
      expect(find.text('No terminals'), findsNothing);
      expect(
        find.text('Open a shell to interact with your project'),
        findsNothing,
      );
    });

    testWidgets('reports a failed attach and offers both ways forward', (
      tester,
    ) async {
      final session = await _pumpEmptyList(
        tester,
        CheckoutAttachStatus.failed,
      );

      expect(find.text("Couldn't load terminals"), findsOneWidget);
      expect(find.text('the agent has not answered yet'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // Opening a shell works whether or not the re-ask lands, so the failure
      // state keeps it beside Retry.
      expect(find.text('New Terminal'), findsOneWidget);
      expect(find.text('No terminals'), findsNothing);

      // The pane renders off the stubbed provider above, so the tap is
      // asserted where it actually lands: the real per-project service, whose
      // verdict is still the constructor default until Retry moves it.
      final service = session.servicesForCheckout('main').terminalService;
      expect(service.currentState.attach, CheckoutAttachStatus.unknown);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(service.currentState.attach, CheckoutAttachStatus.attaching);
    });

    testWidgets('renders the neutral empty state once the checkout is ready', (
      tester,
    ) async {
      await _pumpEmptyList(tester, CheckoutAttachStatus.ready);

      expect(find.text('No terminals'), findsOneWidget);
      expect(
        find.text('Open a shell to interact with your project'),
        findsOneWidget,
      );
      expect(find.text('New Terminal'), findsOneWidget);
      expect(find.text('attaching terminals…'), findsNothing);
      expect(find.text("Couldn't load terminals"), findsNothing);
    });

    testWidgets('renders the neutral empty state for a state nobody derived', (
      tester,
    ) async {
      // A stubbed or absent TerminalState must not claim progress it cannot
      // bound — the timers that would end it live in a service that is not
      // there.
      await _pumpEmptyList(
        tester,
        CheckoutAttachStatus.unknown,
      );

      expect(find.text('No terminals'), findsOneWidget);
      expect(
        find.text('Open a shell to interact with your project'),
        findsOneWidget,
      );
      expect(find.text('attaching terminals…'), findsNothing);
      expect(find.text("Couldn't load terminals"), findsNothing);
    });
  });
}
