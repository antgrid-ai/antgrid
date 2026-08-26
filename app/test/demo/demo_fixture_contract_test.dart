// The demo's frames are hand-written maps, not values produced by a codec, so
// the one thing that can silently break it is a key the real parser doesn't
// recognise: `parseAbMessage` returns null, the router drops the frame, and the
// surface it fed just renders empty. Nothing else in the app would notice.
//
// This walks every frame the demo can ever emit — the static fixtures, the
// opening script, and the reply to every verb the transport handles — through
// the SAME classifier and parser the live wire goes through.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/demo_script.dart';
import 'package:antgrid/demo/demo_transport.dart';
import 'package:antgrid/demo/fixtures/demo_transcript_fixtures.dart';
import 'package:antgrid/demo/fixtures/demo_workspace_fixtures.dart';
import 'package:antgrid/models/ab_config.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_message_classification.dart';
import 'package:antgrid/services/config_service.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Frames `parseAbMessage` has no case for by design: `SessionsService`,
/// `ConfigService` and `UploadService` subscribe to the RAW status JSON and
/// decode these themselves, so a null from the parser is correct for them and
/// says nothing about whether the frame is well formed.
///
/// An exemption here removes the ONLY automated check a demo frame gets, so
/// every type listed is re-checked against its real consumer below — that is
/// what makes the exemption safe rather than a hole. `session:updated` is the
/// one entry with no such test: the demo emits none (see the `session:start`
/// arm in `demo_transport.dart`), so there is nothing to decode. Emit one and
/// it needs a check here first.
const Set<String> _rawConsumedTypes = <String>{
  'session:list:result',
  'session:result',
  'session:updated',
  'config:read-result',
  'config:write-result',
  'config:detect-tools-result',
  'file:upload-result',
};

/// The two hurdles a frame clears to reach a reducer, in the order the app puts
/// them: `MessageRouter` tiers on the classifier, then the tier's subscriber
/// parses. Failing either drops the frame silently, which in the demo shows up
/// only as a surface that stays empty.
void expectRoutable(Map<String, Object?> frame) {
  final type = frame['type'] as String?;
  final json = <String, dynamic>{'id': 'contract', 'timestamp': 0, ...frame};
  expect(
    classifyAbMessage(json),
    isNot(MessageTier.ignore),
    reason: 'MessageRouter drops a demo frame of type "$type"',
  );
  if (_rawConsumedTypes.contains(type)) return;
  expect(
    parseAbMessage(json),
    isNotNull,
    reason: 'parseAbMessage dropped a demo frame of type "$type"',
  );
}

/// Drives [message] through a connected transport and returns everything it
/// published in reply.
Future<List<Map<String, dynamic>>> replies(Map<String, dynamic> message) async {
  final transport = DemoTransport();
  await transport.connect();
  final seen = <InboundMessage>[];
  transport.messages.listen(seen.add);
  // The opening script is drained BEFORE the clear, not after the send:
  // `drainScript` flushes the WHOLE queue, and its six still-pending beats
  // would otherwise land in `seen` beside the reply — making "this verb
  // answered" true for every verb, including the ones that answer with
  // nothing.
  transport.drainScript();
  await Future<void>.delayed(Duration.zero);
  seen.clear();

  await transport.send(message);
  transport.drainScript();
  await Future<void>.delayed(Duration.zero);
  await transport.dispose();
  return seen.map((m) => m.json).toList();
}

void main() {
  final now = DateTime(2026, 3, 4, 10, 30);

  test('the connect-time snapshot routes', () async {
    final transport = DemoTransport(now: now);
    addTearDown(transport.dispose);
    await transport.connect();

    expect(transport.snapshotCache, isNotEmpty);
    for (final message in transport.snapshotCache) {
      expectRoutable(message.json);
    }
  });

  test('the opening script routes', () {
    expect(kDemoScript, isNotEmpty);
    for (final beat in kDemoScript) {
      expectRoutable(beat.frame);
    }
  });

  test('the standalone workspace fixtures route', () {
    for (final frame in <Map<String, Object?>>[
      ...kDemoDurableFrames,
      kDemoTerminalStarted,
      kDemoTerminalSnapshot,
      kDemoGitBranches,
      kDemoPortsUpdate,
      kDemoPreviewUrl,
      kDemoPreviewSnapshot,
      demoCapabilities(kDemoSessionCheckoutId),
    ]) {
      expectRoutable(frame);
    }
  });

  test('every transcript frame routes', () {
    final transcripts = demoTranscripts(now);
    expect(
      transcripts.keys,
      containsAll(<String>[kDemoSessionCheckoutId, kDemoSessionCartId]),
    );
    for (final frames in transcripts.values) {
      expect(frames, isNotEmpty);
      for (final frame in frames) {
        expectRoutable(frame);
      }
    }
  });

  test('a canned reply turn routes', () {
    final beats = demoPromptReplyBeats(
      sessionId: kDemoSessionCheckoutId,
      turnId: 'turn-1',
      promptText: 'hello',
    );
    expect(beats, isNotEmpty);
    for (final beat in beats) {
      expectRoutable(beat.frame);
    }
  });

  // Every verb `_repliesFor` handles, so a reply built with a stale key fails
  // here rather than leaving a spinner up in the demo.
  test('every answered verb replies with routable frames', () async {
    final verbs = <Map<String, dynamic>>[
      {'type': 'session:list', 'requestId': 'q'},
      {
        'type': 'session:start',
        'requestId': 'q',
        'sessionId': kDemoSessionCheckoutId,
      },
      {
        'type': 'session:stop',
        'requestId': 'q',
        'sessionId': kDemoSessionCheckoutId,
      },
      {'type': 'session:create', 'requestId': 'q'},
      {
        'type': 'session:delete',
        'requestId': 'q',
        'sessionId': kDemoSessionCartId,
      },
      {
        'type': 'session:rename',
        'requestId': 'q',
        'sessionId': kDemoSessionCartId,
      },
      {
        'type': 'session:archive',
        'requestId': 'q',
        'sessionId': kDemoSessionCartId,
      },
      {
        'type': 'session:unarchive',
        'requestId': 'q',
        'sessionId': kDemoSessionCartId,
      },
      {
        'type': 'session:set-mode',
        'requestId': 'q',
        'sessionId': kDemoSessionCartId,
      },
      {'type': 'file:read', 'path': kDemoFileContents.keys.first},
      {'type': 'file:read', 'path': 'not/in/the/sample.ts'},
      {'type': 'file:tree:snapshot:request'},
      {'type': 'preview:snapshot:request'},
      {'type': 'terminal:snapshot:request'},
      {'type': 'terminal:start'},
      {'type': 'terminal:input', 'terminalId': kDemoTerminalId, 'data': 'ls\r'},
      {'type': 'terminal:input', 'terminalId': 'demo-terminal-2', 'data': 'ls'},
      {'type': 'terminal:start', 'terminalId': 'demo-terminal-2'},
      {'type': 'terminal:snapshot:request', 'terminalId': 'demo-terminal-2'},
      {
        'type': 'agent:set-config',
        'sessionId': kDemoSessionCheckoutId,
        'key': 'mode',
        'value': 'auto',
      },
      {'type': 'config:read'},
      {'type': 'config:write'},
      {'type': 'config:detect-tools'},
      {'type': 'git:diff', 'path': kDemoGitDiffContent.keys.first},
      {'type': 'git:list-branches'},
      {'type': 'git:checkout', 'branch': 'main'},
      {'type': 'git:commit', 'message': 'wip'},
      {
        'type': 'git:discard',
        'files': <String>['src/checkout.ts'],
      },
      {
        'type': 'git:stage',
        'files': <String>['src/checkout.ts'],
      },
      {
        'type': 'git:unstage',
        'files': <String>['src/checkout.ts'],
      },
      {'type': 'file:search', 'requestId': 'q', 'query': 'quantity'},
      {'type': 'command:run', 'commandName': 'test'},
      {'type': 'file:upload-start', 'requestId': 'q'},
      {
        'type': 'agent:prompt',
        'sessionId': kDemoSessionCheckoutId,
        'text': 'hi',
      },
    ];

    for (final verb in verbs) {
      final answered = await replies(verb);
      expect(
        answered,
        isNotEmpty,
        reason: 'the demo answered "${verb['type']}" with nothing',
      );
      for (final frame in answered) {
        expectRoutable(frame);
      }
    }
  });

  // The parser-less set, checked against its real consumer instead.
  group('session status frames', () {
    test('the list result decodes into SessionEntry rows', () {
      final result = demoSessionsListResult(
        requestId: 'q',
        entries: demoSessionEntries(now),
      );
      expect(result['type'], 'session:list:result');
      final rows = (result['sessions'] as List).cast<Map<String, dynamic>>();
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final entry = SessionEntry.fromJson(row);
        expect(entry.id, isNotEmpty);
        expect(entry.name, isNotEmpty);
        // The Recent list orders on these; a zero would sort the demo to 1970.
        expect(entry.createdAt, greaterThan(0));
        expect(entry.lastUsedAt, greaterThan(0));
      }
    });

    test('a refused mutation carries the reason the UI shows', () async {
      final answered = await replies({
        'type': 'session:create',
        'requestId': 'q',
      });
      final result = answered.firstWhere((f) => f['type'] == 'session:result');
      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(result['errorCode'], isNotEmpty);
    });
  });

  // The other half of the parser-less set. `ConfigService._handleReadResult`
  // and friends cast rather than tolerate (`j['ok'] as bool`), so a key spelled
  // wrong here is a throw inside the status subscription, not an empty surface.
  group('config status frames', () {
    test('the read result decodes into the sample AbConfig', () async {
      final answered = await replies({'type': 'config:read'});
      final result = answered.firstWhere(
        (f) => f['type'] == 'config:read-result',
      );
      expect(result['ok'], isTrue);
      final cfg = AbConfig.fromJson(result['config'] as Map<String, dynamic>);
      expect(cfg.name, kDemoDisplayName);
      expect(cfg.agent?.tool, kDemoAgentTool);
      // Both lists are also rendered from `agent:status`, one tab away from
      // Project Settings — an empty one here is the two disagreeing.
      expect(cfg.services, isNotEmpty);
      expect(cfg.commands, isNotEmpty);
    });

    test(
      'the write refusal carries the reason under the key the UI reads',
      () async {
        final answered = await replies({'type': 'config:write'});
        final result = answered.firstWhere(
          (f) => f['type'] == 'config:write-result',
        );
        expect(result['ok'], isFalse);
        // `errors`, plural — `_handleWriteResult` completes the caller with this
        // list, and Save reports "no reason given" when it is empty.
        expect((result['errors'] as List).cast<String>(), isNotEmpty);
      },
    );

    test('the detect result decodes into DetectedTool rows', () async {
      final answered = await replies({'type': 'config:detect-tools'});
      final result = answered.firstWhere(
        (f) => f['type'] == 'config:detect-tools-result',
      );
      final tools = (result['tools'] as List)
          .map((e) => DetectedTool.fromJson(e as Map<String, dynamic>))
          .toList();
      // Empty is the honest answer — the demo probes no machine — but the key
      // has to exist and hold a list, or the decode above throws.
      expect(tools, isEmpty);
    });
  });

  test('the upload refusal names a code and a sentence', () async {
    final answered = await replies({
      'type': 'file:upload-start',
      'requestId': 'q',
    });
    final result = answered.firstWhere(
      (f) => f['type'] == 'file:upload-result',
    );
    expect(result['ok'], isFalse);
    // `UploadService._throwIfFailed` reads `error` as the CODE and `message` as
    // the sentence, and `uploadErrorText` shows the code when the sentence is
    // missing — which would put E_DEMO_UNSUPPORTED in front of the user.
    expect(result['error'], kDemoRefusalCode);
    expect(result['message'], isNotEmpty);
  });

  test('the sessions the list advertises are the ones with transcripts', () {
    final listed = demoSessionEntries(now).map((s) => s['id']).toSet();
    expect(demoTranscripts(now).keys.toSet(), listed);
  });
}
