// The sentence a session was started with is the only statement of intent the
// app can hand Handler when it is armed later, on another surface. The bridge
// takes `initialPrompt` as one-shot launch argv and never persists it, and the
// composer's draft is cleared the moment a start is accepted, so this provider
// is the whole of what remembers it.
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/session_opening_prompt.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _projectId = 'P';

Map<String, dynamic> get _created => <String, dynamic>{
  'id': 'B',
  'name': 'new one',
  'createdAt': 1000,
  'lastUsedAt': 1000,
  'archived': false,
  'running': false,
};

/// Answers create and start immediately — this file is about what the start
/// leaves behind, not about the reply's timing.
class _StartingTransport extends FakeAgentTransport {
  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    await super.send(message, channel: channel);
    switch (message['type']) {
      case 'session:create':
      case 'session:start':
        emit('session:result', {
          'requestId': message['requestId'],
          'ok': true,
          'session': _created,
        });
    }
  }
}

Future<ProviderContainer> _openCanvas(
  _StartingTransport transport, {
  required String prompt,
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  final container = ProviderContainer(
    overrides: [
      ...stores.overrides,
      agentTransportForProvider.overrideWith((ref, id) async => transport),
      newSessionIsolationReadyProvider.overrideWithValue(true),
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
  container.read(newSessionNameProvider.notifier).set('new one');
  container.read(newSessionPromptProvider.notifier).set(prompt);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionOpeningPrompts', () {
    test('trims, and a blank prompt records nothing', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prompts = container.read(sessionOpeningPromptsProvider.notifier);

      prompts.remember('a', '  ship the fix  ');
      prompts.remember('b', '   ');

      expect(container.read(sessionOpeningPromptsProvider), {
        'a': 'ship the fix',
      });
    });

    test('the cap drops the oldest, and re-recording refreshes a key', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prompts = container.read(sessionOpeningPromptsProvider.notifier);

      prompts.remember('oldest', 'first');
      // Touching it again must make it the newest, or the refresh a re-created
      // session gets would still be the next thing evicted.
      prompts.remember('oldest', 'first again');
      for (var i = 0; i < kSessionOpeningPromptCap; i++) {
        prompts.remember('s$i', 'work $i');
      }

      final kept = container.read(sessionOpeningPromptsProvider);
      expect(kept.length, kSessionOpeningPromptCap);
      expect(kept.containsKey('oldest'), isFalse);
      expect(kept['s0'], 'work 0');

      prompts.remember('newest', 'last');
      final after = container.read(sessionOpeningPromptsProvider);
      expect(after.containsKey('s0'), isFalse);
      expect(after['newest'], 'last');
    });

    // The composer takes a pasted spec without complaint, and this string is
    // sent as the goal — which the bridge puts into every judge prompt and into
    // the wrap-up push, neither of which bounds it.
    test('a pasted essay is clamped to one item\'s worth of text', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prompts = container.read(sessionOpeningPromptsProvider.notifier);

      prompts.remember('a', 'x' * 15000);

      expect(
        container.read(sessionOpeningPromptsProvider)['a'],
        'x' * kSessionOpeningPromptChars,
      );
    });

    test('a cut never strands half a surrogate pair', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prompts = container.read(sessionOpeningPromptsProvider.notifier);

      // One emoji straddles the bound: 399 filler code units, then a pair.
      prompts.remember('a', '${'x' * (kSessionOpeningPromptChars - 1)}🚀tail');

      final kept = container.read(sessionOpeningPromptsProvider)['a']!;
      expect(kept, 'x' * (kSessionOpeningPromptChars - 1));
      expect(kept.codeUnits.every((u) => u < 0xD800 || u > 0xDFFF), isTrue);
    });

    test('forget drops one session and leaves the rest', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prompts = container.read(sessionOpeningPromptsProvider.notifier);

      prompts.remember('a', 'ship the fix');
      prompts.remember('b', 'revert the migration');
      prompts.forget('a');
      // A session nothing remembers is not an error — an arm asks for every
      // terminal it confirms.
      prompts.forget('nothing');

      expect(container.read(sessionOpeningPromptsProvider), {
        'b': 'revert the migration',
      });
    });
  });

  test('a start records its prompt against the session id', () async {
    final transport = _StartingTransport();
    final container = await _openCanvas(
      transport,
      prompt: 'fix the flaky login test',
    );

    await startNewSession(container);

    expect(container.read(sessionOpeningPromptsProvider), {
      'B': 'fix the flaky login test',
    });
    // The draft is consumed, which is exactly why nothing else still holds it.
    expect(container.read(newSessionPromptProvider), '');
  });

  test('the start itself is unchanged — same frames, same prompt', () async {
    final transport = _StartingTransport();
    final container = await _openCanvas(
      transport,
      prompt: 'fix the flaky login test',
    );

    await startNewSession(container);

    expect(
      transport.sent.map((m) => m['type']).toList(),
      containsAllInOrder(['session:create', 'session:start']),
    );
    expect(
      transport.sent.any((m) => (m['type'] as String).startsWith('handler:')),
      isFalse,
    );
    expect(
      transport.sent.firstWhere(
        (m) => m['type'] == 'session:start',
      )['initialPrompt'],
      'fix the flaky login test',
    );
  });

  test('an empty composer leaves the session with nothing to arm on', () async {
    final transport = _StartingTransport();
    final container = await _openCanvas(transport, prompt: '');

    await startNewSession(container);

    expect(container.read(sessionOpeningPromptsProvider), isEmpty);
    expect(
      transport.sent
          .firstWhere((m) => m['type'] == 'session:start')
          .containsKey('initialPrompt'),
      isFalse,
    );
  });
}
