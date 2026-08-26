// The New Session canvas hands the user their session on the CREATE, not on the
// start. An isolated session's `session:start` is queued behind the checkout's
// `worktree.setup` run and answered `ok: true` immediately with
// `setup.pendingStart` set, so its reply says nothing about whether the agent
// is live — waiting on it would hold the canvas over a session the user is
// already owed, for as long as the install takes.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/session_setup.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _projectId = 'P';

/// Answers `session:create` immediately and holds `session:start` until the
/// test releases it — which is what lets the assertions look at the app in the
/// window the whole change is about: the start is on the wire, its reply is not.
class _QueuedStartTransport extends FakeAgentTransport {
  _QueuedStartTransport({this.createOk = true, this.startEntry});

  final bool createOk;

  /// The entry the bridge returns for the start, or null for a bare rejection
  /// (`ok: true` with no session — an older agent refusing the tool).
  final Map<String, dynamic>? startEntry;

  Map<String, dynamic>? _pendingStartRequest;

  bool get startSent => _pendingStartRequest != null;

  void releaseStart() {
    final req = _pendingStartRequest!;
    emit('session:result', {
      'requestId': req['requestId'],
      'ok': true,
      if (startEntry != null) 'session': startEntry,
    });
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    await super.send(message, channel: channel);
    switch (message['type']) {
      case 'session:create':
        emit('session:result', {
          'requestId': message['requestId'],
          'ok': createOk,
          if (createOk) 'session': _created,
          if (!createOk) 'error': 'Session limit reached',
        });
      case 'session:start':
        _pendingStartRequest = message;
    }
  }
}

Map<String, dynamic> get _created => <String, dynamic>{
  'id': 'B',
  'name': 'new one',
  'createdAt': 1000,
  'lastUsedAt': 1000,
  'archived': false,
  'running': false,
  'checkoutId': 'worktree-1',
  'checkoutKind': 'managed-worktree',
  'checkoutBranch': 'antgrid/session-B',
  'checkoutState': 'ready',
  'setup': {
    'state': 'running',
    'stepIndex': 0,
    'stepCount': 4,
    'stepName': 'Copy env files',
    'terminalId': 'worktree-1:setup',
    'pendingStart': true,
    'startedAt': 1000,
  },
};

Future<ProviderContainer> _openCanvas(_QueuedStartTransport transport) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  final container = ProviderContainer(
    overrides: [
      ...stores.overrides,
      agentTransportForProvider.overrideWith((ref, id) async => transport),
      // The catalog gate for the isolation toggle. Its real source dials the
      // target for a branch listing, which a provider test has no machine for.
      newSessionIsolationReadyProvider.overrideWithValue(true),
      // Left to itself this reaches for the local host process to list tools.
      newSessionChatCapableToolsProvider.overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);

  enterNewSession(container);
  container
      .read(selectedTargetProjectProvider.notifier)
      .set(
        const PickerProject(
          id: _projectId,
          name: 'p',
          detail: '/tmp/p',
          isLocal: true,
        ),
      );
  container.read(newSessionIsolatedProvider.notifier).set(true);
  container.read(newSessionNameProvider.notifier).set('new one');
  container.read(newSessionPromptProvider.notifier).set('fix the build');
  return container;
}

/// Lets the microtasks of [startNewSession] run without completing it — the
/// start reply is what it is still waiting on.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the session is handed over on the create, not on the start', () async {
    final transport = _QueuedStartTransport(startEntry: _created);
    final container = await _openCanvas(transport);

    final start = startNewSession(container);
    await _settle();

    // The start is on the wire and unanswered — and the user is already in the
    // session, with the canvas behind them.
    expect(transport.startSent, isTrue);
    expect(container.read(activeSessionIdProvider), 'B');
    // The remount's bootstrap re-derives focus from `lastUsedAt`, which records
    // activity rather than intent; this names the session the user asked for.
    expect(container.read(pendingActiveSessionIdProvider), 'B');
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );

    transport.releaseStart();
    await start;
  });

  // The start goes out BEFORE the canvas closes: leaving remounts WorkspaceShell,
  // whose bootstrap re-lists the sessions and starts the one it adopts. Issuing
  // the start first puts it ahead of that list on the same stream.
  test('the start precedes the navigation on the wire', () async {
    final transport = _QueuedStartTransport(startEntry: _created);
    final container = await _openCanvas(transport);

    final start = startNewSession(container);
    await _settle();

    final types = transport.sent.map((m) => m['type']).toList();
    expect(
      types.indexOf('session:create'),
      lessThan(types.indexOf('session:start')),
    );
    expect(
      transport.sent.firstWhere(
        (m) => m['type'] == 'session:start',
      )['initialPrompt'],
      'fix the build',
    );

    transport.releaseStart();
    await start;
  });

  test('a queued start consumes the draft like a live one', () async {
    final transport = _QueuedStartTransport(startEntry: _created);
    final container = await _openCanvas(transport);

    final start = startNewSession(container);
    await _settle();
    transport.releaseStart();
    await start;

    // The entry the bridge answered with carries `pendingStart`, so the agent
    // is NOT live — and that is still a success: the session exists and is the
    // user's, so nothing is left on the canvas to retry.
    expect(sessionStartQueued(SessionEntry.fromJson(_created).setup), isTrue);
    expect(container.read(newSessionPromptProvider), '');
    expect(container.read(newSessionNameProvider), '');
    expect(container.read(selectedTargetProjectProvider), isNull);
  });

  // The contrast case: `ok: true` with no session is a bare rejection, and the
  // draft has to survive it so the canvas is retryable.
  test('a start that comes back with no session keeps the draft', () async {
    final transport = _QueuedStartTransport(startEntry: null);
    final container = await _openCanvas(transport);

    final start = startNewSession(container);
    await _settle();
    transport.releaseStart();
    await start;

    expect(container.read(newSessionPromptProvider), 'fix the build');
    expect(container.read(newSessionNameProvider), 'new one');
    // Navigation already happened — once the session exists it is the user's,
    // and the place to report anything further about it is the session itself.
    expect(container.read(activeSessionIdProvider), 'B');
  });

  // Only CREATE keeps the user here. This is the behaviour the change had to
  // preserve, and it is the one the navigate-early path could most easily lose.
  test('a create failure leaves the user on the canvas', () async {
    final transport = _QueuedStartTransport(createOk: false);
    final container = await _openCanvas(transport);

    // A coded refusal still raises past here — the composer renders it. What
    // matters is that nothing was navigated or consumed on the way out.
    await expectLater(
      startNewSession(container),
      throwsA(isA<SessionOperationException>()),
    );

    expect(transport.sent.any((m) => m['type'] == 'session:start'), isFalse);
    expect(container.read(activeSessionIdProvider), isNull);
    expect(container.read(pendingActiveSessionIdProvider), isNull);
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.newSession,
    );
    expect(container.read(newSessionPromptProvider), 'fix the build');
  });
}
