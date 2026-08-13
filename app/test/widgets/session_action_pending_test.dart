// Both session actions that can wait on a project warm-up (up to 10s) plus a
// bridge round trip (up to 15s) have to say they are working, and go inert so a
// second press can't queue a second request behind the first. Same shape
// SessionModeControl uses for a mode flip: show what the user asked for, pulse
// it, and take the control out of play until it is answered.
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/design/widgets/pulsing_opacity.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/screens/terminal_screen.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _projectId = 'pending-proj';

SessionEntry _session({bool running = false, String name = 'Session 1'}) =>
    SessionEntry(
      id: 'sess-1',
      name: name,
      createdAt: 0,
      lastUsedAt: 0,
      archived: false,
      running: running,
      mode: 'terminal',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAgentTransport transport;
  late ProjectSession session;

  setUp(() async {
    useInMemoryPrefs();
    transport = FakeAgentTransport();
    session = ProjectSession(
      projectId: _projectId,
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: await CachedSessionsStore.open(),
      onClose: () async => transport.dispose(),
    );
  });
  tearDown(() async => session.close());

  // The project resolves immediately here, so what these tests exercise is the
  // wait on the BRIDGE. The warm-up leg is covered in
  // focused_service_or_null_test.dart.
  Widget host(Widget child) => ProviderScope(
    overrides: [
      selectedRegistrationIdProvider.overrideWith((_) => _projectId),
      projectSessionProvider(_projectId).overrideWith((ref) async => session),
      activeSessionProvider.overrideWithValue(_session()),
      terminalStateProvider.overrideWith(
        (ref) => Stream.value(const TerminalState()),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  testWidgets('the Start button reports the start it is waiting on', (
    tester,
  ) async {
    await tester.pumpWidget(host(const TerminalScreen()));
    await tester.pump();
    await tester.pump();

    expect(find.text('Start'), findsOneWidget);
    expect(find.byType(AbLoadingDot), findsNothing);

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();

    expect(
      transport.sent.where((m) => m['type'] == 'session:start'),
      hasLength(1),
    );
    expect(find.text('Starting…'), findsOneWidget);
    expect(find.text('Start'), findsNothing);
    expect(
      find.byType(AbLoadingDot),
      findsOneWidget,
      reason: 'the dot is what separates busy from a button that died',
    );

    // Inert: a second press must not queue a second start behind the first.
    await tester.tap(find.text('Starting…'), warnIfMissed: false);
    await tester.pump();
    expect(
      transport.sent.where((m) => m['type'] == 'session:start'),
      hasLength(1),
    );

    // Never answered — past the 15s pending-reply bound the button comes back
    // rather than sitting on a spinner forever.
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);
    expect(find.byType(AbLoadingDot), findsNothing);
    expect(find.textContaining("didn't answer"), findsOneWidget);
  });

  testWidgets('the breadcrumb shows the asked-for name while committing', (
    tester,
  ) async {
    await tester.pumpWidget(host(EditableSessionLeaf(session: _session())));
    await tester.pump();

    await tester.tap(find.text('Session 1'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Renamed');
    await tester.tap(find.text('Rename'));
    // Let the dialog route finish popping before matching on text: its field
    // holds the same string. The rename stays in flight throughout — the 15s
    // pending-reply bound dwarfs the transition.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      transport.sent.where((m) => m['type'] == 'session:rename'),
      hasLength(1),
    );
    // The asked-for name, pulsing — not a claim that it landed, and not the old
    // name either, which would read as a rename that did nothing.
    expect(find.text('Renamed'), findsOneWidget);
    expect(find.byType(PulsingOpacity), findsOneWidget);

    // Inert while committing: the dialog is the only way in, and a second one
    // would race the first rename.
    await tester.tap(find.text('Renamed'), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);

    // Unanswered: the committed name comes back with the reason, rather than a
    // name the bridge never confirmed sticking on screen.
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(find.text('Session 1'), findsOneWidget);
    expect(find.byType(PulsingOpacity), findsNothing);
    expect(find.textContaining("didn't answer"), findsOneWidget);
  });
}
