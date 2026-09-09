// A held keystroke is REFUSED, never queued and replayed. A
// delayed `y<Enter>` replayed against a prompt that has moved on can confirm
// something the user never saw, which is a correctness hazard worse than the
// silence it replaces — see TerminalService.sendInput.

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> newSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  /// The refusal latch is cleared by the hydrator re-drive, and both the
  /// hydrator and the focus-resume subscription are activation-gated — this is
  /// the checkout on screen, the one `setActiveCheckouts` always names.
  TerminalService newService(ProjectSession session) =>
      TerminalService.fromSession(session)..activate();

  /// Drains the delivery chain and the microtask the hydration re-emit is
  /// coalesced onto.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// The paused -> resumed edge `focusResumed` fires on, mirroring
  /// terminal_attach_state_test.dart's helper of the same shape.
  Future<void> resumeFocus(ProjectSession session) async {
    session.setLifecyclePaused(true);
    await settle();
    session.setLifecyclePaused(false);
    await settle();
    await settle();
  }

  Iterable<Map<String, dynamic>> inputFrames(FakeAgentTransport t) =>
      t.sent.where((m) => m['type'] == 'terminal:input');

  test('input is refused, not queued, while the transport is down', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = newService(session);
    t.setEstablished(false);

    final ok = svc.sendInput('terminal-1', 'y\n');
    await settle();

    expect(ok, isFalse);
    expect(inputFrames(t), isEmpty);
    expect(svc.currentState.inputPaused, isTrue);

    await svc.dispose();
    await session.close();
  });

  test(
    'nothing typed while paused is replayed when the transport returns',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = newService(session);
      t.setEstablished(false);

      expect(svc.sendInput('terminal-1', 'y\n'), isFalse);
      await settle();
      expect(svc.currentState.inputPaused, isTrue);

      // The hydrator re-drive clears the pane, not a replay of what was
      // refused — nothing was ever held to replay.
      t.setEstablished(true);
      await settle();

      expect(svc.currentState.inputPaused, isFalse);
      expect(
        inputFrames(t),
        isEmpty,
        reason:
            'the refused keystroke must never leave, replayed or otherwise — '
            'the pin that stops refusal regressing into a buffer',
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'sendToAgentTerminal is refused by the same gate and reports it',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = newService(session);

      t.emit('agent:status', {
        'projectId': 'p',
        'terminals': [
          {
            'id': 'agent',
            'terminalId': 'agent',
            'name': 'agent',
            'type': 'agent',
            'running': true,
          },
        ],
      });
      await settle();
      t.setEstablished(false);

      final ok = svc.sendToAgentTerminal('go ahead\n');
      await settle();

      expect(ok, isFalse);
      expect(inputFrames(t), isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test('a focused pane reports paused before any keystroke', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = newService(session);
    t.setEstablished(false);

    await resumeFocus(session);

    expect(svc.currentState.inputPaused, isTrue);
    expect(
      inputFrames(t),
      isEmpty,
      reason: 'inputPaused must be known without ever calling sendInput',
    );

    await svc.dispose();
    await session.close();
  });

  test('a foregrounded pane clears a refusal the reconnect already fixed', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = newService(session);
    t.setEstablished(false);

    expect(svc.sendInput('terminal-1', 'y\n'), isFalse);
    await settle();
    expect(svc.currentState.inputPaused, isTrue);

    // A backgrounded app misses the re-establish that would have cleared the
    // latch, so focus resume has to carry the same sync — otherwise the pane
    // comes back saying input is paused over a transport that is fine.
    t.setEstablishedQuietly(true);
    await resumeFocus(session);

    expect(svc.currentState.inputPaused, isFalse);

    await svc.dispose();
    await session.close();
  });

  test('an established transport still sends', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = newService(session);

    final ok = svc.sendInput('terminal-1', 'ls\n');
    await settle();

    expect(ok, isTrue);
    expect(inputFrames(t), hasLength(1));
    expect(svc.currentState.inputPaused, isFalse);

    await svc.dispose();
    await session.close();
  });
}
