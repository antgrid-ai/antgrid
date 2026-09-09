// Every send-to-agent surface routes its text through `sendCaptureToAgent`,
// which must refuse visibly rather than report success when the transport
// can't carry it. Mounted here are the three surfaces outside the terminal
// pane; the pane's own selection route shares that helper and has no path of
// its own left to test separately. Every scenario below drives a REAL
// TerminalService (via a real ProjectSession over a FakeAgentTransport) with
// a genuine running agent tab, so a refusal here is provably about
// `isEstablished`, not about "no agent tab" — a different silent case
// `sendToAgentTerminal` also answers false for.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/session_mode.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/command_output_overlay.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:antgrid/widgets/send_capture_to_agent.dart';
import 'package:antgrid/widgets/send_to_agent_button.dart';

import '../helpers/prefs_test_mock.dart';

const _kEntryId = 'p';
const _kRefusalText = "couldn't send — the session is reconnecting";

/// A real, running agent tab — `agent:status` as the bridge replays it. Every
/// scenario needs one present before its transport-down check even applies:
/// `sendToAgentTerminal` answers false for "no agent tab" the same way it does
/// for a refused send, so without this a refusal test would prove nothing
/// about the transport gate specifically.
Map<String, dynamic> _agentStatus() => {
  'projectId': _kEntryId,
  'terminals': [
    {'terminalId': 'agent-1', 'name': 'Agent', 'running': true, 'type': 'agent'},
  ],
};

class _Session {
  _Session(this.session, this.transport);
  final ProjectSession session;
  final FakeAgentTransport transport;
}

Future<_Session> _buildSession() async {
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: _kEntryId,
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => transport.dispose(),
  );
  return _Session(session, transport);
}

/// Pumps [child] behind a real, resolved [ProjectSession] so
/// `focusedCheckoutServiceOrNull` (what every call site under test reads)
/// resolves to the session's actual TerminalService rather than null.
Future<({BuildContext context, ProviderContainer container})> _pump(
  WidgetTester tester,
  _Session s,
  Widget child, {
  List<Override> extraOverrides = const [],
}) async {
  late BuildContext captured;
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue(_kEntryId),
        projectSessionProvider.overrideWith((ref, id) async => s.session),
        ...extraOverrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              captured = context;
              container = ref.container;
              return child;
            },
          ),
        ),
      ),
    ),
  );
  // `focusedCheckoutServiceOrNull` reads the session provider's CURRENT value
  // and answers null while it is still loading, so a surface that watches
  // nothing (the capture route) would otherwise report "not connected" and
  // never reach the transport gate this file is about.
  await container.read(projectSessionProvider(_kEntryId).future);
  await tester.pump();
  await tester.pump();
  return (context: captured, container: container);
}

/// The binding asserts no Timer is pending BEFORE any tearDown runs, and a
/// running agent tab arms both a snapshot deadline and a checkout-attach
/// bound. Retired by letting them expire rather than by disposing the
/// service: dispose() awaits real stream cancellations, and awaiting real
/// async inside a testWidgets body wedges with no timeout.
Future<void> _quiesce(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 31));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CommandOutputOverlay', () {
    testWidgets('refuses a send while the transport is down', (
      tester,
    ) async {
      final s = await _buildSession();
      addTearDown(() => unawaited(s.session.close()));
      s.transport.setEstablished(false);

      var switched = false;
      void onSwitch() => switched = true;
      await _pump(
        tester,
        s,
        const Stack(children: [CommandOutputOverlay()]),
        extraOverrides: [
          switchToAgentProvider.overrideWith(() => ValueController(onSwitch)),
        ],
      );

      s.transport.emit('agent:status', _agentStatus());
      await tester.pump();

      s.session.commandService.runCommand('build');
      await tester.pump();

      s.transport.emit('command:output', {
        'projectId': s.session.wireProjectId,
        'commandName': 'build',
        'data': 'boom',
      });
      // The service batches output behind a 16ms flush timer.
      await tester.pump(const Duration(milliseconds: 20));

      s.transport.emit('command:done', {
        'projectId': s.session.wireProjectId,
        'commandName': 'build',
        'exitCode': 1,
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('Send to Agent'), findsOneWidget);
      await tester.tap(find.text('Send to Agent'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The comment dialog opens as a centred popover at the default
      // (desktop-sized) test window; pressing Send with no added comment
      // still produces a message from the captured output alone.
      expect(find.text('Send'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pump();
      await tester.pump();

      expect(find.text(_kRefusalText), findsOneWidget);
      expect(switched, isFalse);
      expect(
        s.transport.sent.where((m) => m['type'] == 'terminal:input'),
        isEmpty,
      );

      await _quiesce(tester);
    });
  });

  group('FileContentViewer', () {
    testWidgets('refuses a send while the transport is down', (
      tester,
    ) async {
      final s = await _buildSession();
      addTearDown(() => unawaited(s.session.close()));
      s.transport.setEstablished(false);

      const content = 'const greeting = "hello world";';
      await _pump(
        tester,
        s,
        FileContentViewer(
          fileContent: FileContent(
            path: 'notes.txt', // unrecognized extension: editor is ready
            content: content, // immediately, no highlight-isolate wait
            size: content.length,
          ),
        ),
      );

      s.transport.emit('agent:status', _agentStatus());
      await tester.pump();

      // Selected through the editor's own controller rather than a synthetic
      // drag: a drag lands wherever the laid-out glyphs happen to be, and one
      // that misses them leaves a non-collapsed selection covering no text —
      // which shows the button and then sends nothing, testing the wrong
      // thing.
      tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!
          .selectAll();
      await tester.pump();

      // Invoked through the button's own callback rather than a pointer: the
      // button shares a Stack with the editor, so a synthetic tap also reaches
      // the editor's tap handler and collapses the very selection the handler
      // is about to read.
      final button = tester.widget<SendToAgentButton>(
        find.byType(SendToAgentButton),
      );
      button.onPressed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Send'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pump();
      await tester.pump();

      expect(find.text(_kRefusalText), findsOneWidget);
      expect(
        s.transport.sent.where((m) => m['type'] == 'terminal:input'),
        isEmpty,
      );

      await _quiesce(tester);
    });
  });

  group('sendCaptureToAgent', () {
    testWidgets('refuses a send while the transport is down', (
      tester,
    ) async {
      final s = await _buildSession();
      addTearDown(() => unawaited(s.session.close()));
      s.transport.setEstablished(false);

      var switched = false;
      void onSwitch() => switched = true;
      final h = await _pump(
        tester,
        s,
        const SizedBox.shrink(),
        extraOverrides: [
          activeSessionModeProvider.overrideWithValue('terminal'),
          switchToAgentProvider.overrideWith(() => ValueController(onSwitch)),
        ],
      );

      s.transport.emit('agent:status', _agentStatus());
      await tester.pump();

      final sent = await sendCaptureToAgent(
        context: h.context,
        container: h.container,
        text: 'look at this',
      );
      await tester.pump();

      expect(sent, isFalse);
      expect(find.text(_kRefusalText), findsOneWidget);
      expect(switched, isFalse);
      expect(
        s.transport.sent.where((m) => m['type'] == 'terminal:input'),
        isEmpty,
      );

      await _quiesce(tester);
    });
  });
}
