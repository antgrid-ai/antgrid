import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/foundation.dart';

import 'demo_identity.dart';
import 'demo_script.dart';
import 'fixtures/demo_transcript_fixtures.dart';
import 'fixtures/demo_workspace_fixtures.dart';

/// Round trip the demo pretends to pay. Long enough that a reply lands after
/// the caller has registered its pending entry and short enough to feel local.
const Duration _kReplyDelay = Duration(milliseconds: 40);

/// An [AgentTransport] backed entirely by canned frames.
///
/// Deliberately a transport rather than a parallel set of fake services: the
/// demo then renders through the real [MessageRouter], the real per-checkout
/// service bundle and the real widgets, so what a reviewer sees is the product
/// and not a mock of it. It opens no socket, reads no keychain and resolves no
/// host — [connect] is pure local work.
class DemoTransport extends BufferedAgentTransport {
  DemoTransport({DateTime? now}) : _now = now ?? DateTime.now();

  /// Anchor for every relative time in the fixtures, so a session row and the
  /// transcript it opens agree on when the conversation happened.
  final DateTime _now;

  final List<_PendingBeat> _queue = <_PendingBeat>[];
  Timer? _timer;
  bool _disposed = false;
  int _frameSeq = 0;
  int _turnSeq = 0;

  /// Insertion order, and the tie-break [_rearm] sorts on. Beats enqueued
  /// together share one `due`, and Dart's sort is stable only below its
  /// insertion-sort threshold — past it a quicksort is free to dispatch
  /// `command:done` ahead of the `command:output` it terminates.
  int _beatSeq = 0;

  /// Session-scoped model/effort/mode picks. The composer is deliberately
  /// non-optimistic: it renders only what a capabilities frame echoes back, so
  /// a pick nothing echoes snaps the pill straight back and reads as dead.
  final Map<String, Map<String, String>> _configPicks =
      <String, Map<String, String>>{};

  /// Built once: the fixtures are pure functions of [_now], and the transcript
  /// RPC runs per session on hydrate and again on every redrive — so a
  /// per-call build would render both transcripts in full to index one of them.
  late final Map<String, List<Map<String, Object?>>> _transcripts =
      demoTranscripts(_now);
  late final List<Map<String, Object?>> _entries = demoSessionEntries(_now);

  /// Split once, for the same reason as [_transcripts]: the file explorer sends
  /// a `file:search` per keystroke with no debounce, and the bodies are `const`.
  late final Map<String, List<String>> _fileLines = {
    for (final e in kDemoFileContents.entries) e.key: e.value.split('\n'),
  };

  @override
  bool get isLocal => true;

  @override
  Future<void> connect() async {
    // Idempotent: `connect` is a public contract method, and a second call
    // would append the whole opening snapshot to `snapshotCache` again while
    // `setState` de-dupes and hides the doubling — every later subscriber then
    // replays each durable frame twice.
    if (_disposed || isEstablished) return;
    for (final frame in _openingFrames()) {
      snapshotCache.add(InboundMessage('control', _stamp(frame)));
    }
    setState(TransportState.connected);
    // Born established, exactly like a local session: no handshake, so this is
    // the only replay any hydrator registered later will need.
    redriveHydrators();
    _enqueue(kDemoScript);
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    if (_disposed) return;
    switch (message['type']) {
      case 'request':
        _answerRpc(message);
        return;
      case 'agent:prompt':
        _playPromptReply(
          message['sessionId'] as String? ?? kDemoSessionCheckoutId,
          message['text'] as String? ?? '',
        );
        return;
      case 'agent:cancel':
        _cancelTurn(
          message['sessionId'] as String?,
          message['turnId'] as String?,
        );
        return;
    }
    _enqueueAll(_kReplyDelay, _repliesFor(message));
  }

  /// Dispatches every queued beat immediately. Tests use it instead of pumping
  /// the script's real delays; nothing in the app calls it.
  @visibleForTesting
  void drainScript() {
    _timer?.cancel();
    _timer = null;
    final due = List<_PendingBeat>.of(_queue);
    _queue.clear();
    for (final beat in due) {
      dispatchDecoded(_stamp(beat.frame), beat.channel);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    failAllPending();
    clearHydrators();
    snapshotCache.clear();
    await outbound.close();
    await stateController.close();
    await droppedFrameController.close();
  }

  // ── canned state ──

  /// What the bridge would have replayed in its connect-time snapshot, plus the
  /// per-session capability frames the composer needs before its first paint.
  List<Map<String, Object?>> _openingFrames() => <Map<String, Object?>>[
    ...kDemoDurableFrames,
    kDemoTerminalStarted,
    kDemoTerminalSnapshot,
    kDemoGitBranches,
    // Read through [_configPicks] rather than [demoCapabilities] directly, so
    // an answer built after the user has picked a model or mode carries the
    // pick. `snapshotCache` is written once at connect, so today only the
    // `state.snapshot` answer below can be that late one.
    _capabilitiesFor(kDemoSessionCheckoutId),
    _capabilitiesFor(kDemoSessionCartId),
  ];

  /// [demoCapabilities] with whatever this session has since been set to.
  Map<String, Object?> _capabilitiesFor(String sessionId) {
    final picks = _configPicks[sessionId];
    final frame = demoCapabilities(sessionId);
    if (picks == null || picks.isEmpty) return frame;
    const fields = <String, String>{
      'model': 'currentModelId',
      'effort': 'currentEffortId',
      'mode': 'currentModeId',
    };
    final out = Map<String, Object?>.of(frame);
    picks.forEach((key, value) {
      final field = fields[key];
      if (field != null) out[field] = value;
    });
    return out;
  }

  /// Adds the envelope fields every consumer expects. Spread last so a fixture
  /// that carries its own `timestamp` — a replayed transcript turn — keeps it.
  Map<String, dynamic> _stamp(Map<String, Object?> frame) => <String, dynamic>{
    'id': 'demo-${_frameSeq++}',
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    ...frame,
  };

  // ── RPC ──

  void _answerRpc(Map<String, dynamic> message) {
    final requestId = message['requestId'] as String?;
    if (requestId == null) return;
    final params =
        (message['params'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    Map<String, Object?> result;
    switch (message['method'] as String?) {
      case 'state.snapshot':
        // Stamped, like the connect-time replay of the very same maps: the two
        // paths serve identical frames, and one of them handing back no `id`
        // and no `timestamp` is a divergence no test would catch.
        result = <String, Object?>{
          'frames': _openingFrames().map(_stamp).toList(),
        };
      case 'session.transcriptSnapshot':
        final sessionId = params['sessionId'] as String?;
        result = <String, Object?>{
          'frames': _transcripts[sessionId] ?? const [],
        };
      case 'sessions.list':
        result = <String, Object?>{'sessions': _entries};
      default:
        _enqueueAll(_kReplyDelay, <Map<String, Object?>>[
          <String, Object?>{
            'type': 'response',
            'requestId': requestId,
            'ok': false,
            'error': <String, Object?>{
              'code': kDemoRefusalCode,
              'message': kDemoRefusalText,
            },
          },
        ]);
        return;
    }
    _enqueueAll(_kReplyDelay, <Map<String, Object?>>[
      <String, Object?>{
        'type': 'response',
        'requestId': requestId,
        'ok': true,
        'result': result,
      },
    ]);
  }

  // ── message replies ──

  /// The frames a real bridge would answer [message] with.
  ///
  /// Every verb the app can send is either answered or deliberately silent
  /// (fire-and-forget ones the bridge never replies to). A verb that falls
  /// through to nothing while its caller waits is the one failure mode a demo
  /// cannot recover from on its own, so the mutating session verbs answer with
  /// a refusal rather than silence.
  List<Map<String, Object?>> _repliesFor(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final requestId = message['requestId'] as String?;
    switch (type) {
      case 'session:list':
        return <Map<String, Object?>>[
          demoSessionsListResult(requestId: requestId ?? '', entries: _entries),
        ];

      // Already running in the fixtures, so this is a no-op that still has to
      // answer: the bootstrap awaits the reply before it focuses a session.
      case 'session:start':
        return <Map<String, Object?>>[
          _sessionResult(
            requestId,
            ok: true,
            entry: _entryFor(message['sessionId'] as String?),
          ),
        ];

      // Stop refuses rather than joining the no-op above. An `ok` carrying the
      // fixture's unchanged `running: true`, with no `session:updated` behind
      // it, leaves the row claiming success while nothing moves — the silent
      // dead end this switch exists to avoid.
      case 'session:stop':
      case 'session:create':
      case 'session:delete':
      case 'session:rename':
      case 'session:archive':
      case 'session:unarchive':
      case 'session:set-mode':
        return <Map<String, Object?>>[_sessionResult(requestId, ok: false)];

      case 'file:read':
        return <Map<String, Object?>>[_fileContent(message['path'] as String?)];

      case 'file:tree:snapshot:request':
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'file:tree:snapshot',
            'checkoutId': 'main',
            'seq': 1,
            'tree': kDemoTreeRoot,
          },
        ];

      case 'preview:snapshot:request':
        return <Map<String, Object?>>[kDemoPreviewSnapshot, kDemoPortsUpdate];

      case 'terminal:snapshot:request':
        return <Map<String, Object?>>[
          _terminalSnapshot(message['terminalId'] as String?),
        ];

      case 'terminal:start':
        return <Map<String, Object?>>[
          _terminalStarted(message['terminalId'] as String?),
        ];

      case 'terminal:input':
        return _terminalEcho(
          message['terminalId'] as String?,
          message['data'] as String?,
        );

      // The composer's pills echo the bridge and nothing else, so a pick this
      // transport swallows springs back to the old label. A session-scoped
      // selection costs the demo nothing to honour, unlike the verbs that
      // would have to touch a machine.
      case 'agent:set-config':
        final sessionId = message['sessionId'] as String?;
        final key = message['key'] as String?;
        final value = message['value'] as String?;
        if (sessionId == null || key == null || value == null) {
          return const <Map<String, Object?>>[];
        }
        (_configPicks[sessionId] ??= <String, String>{})[key] = value;
        return <Map<String, Object?>>[_capabilitiesFor(sessionId)];

      case 'config:read':
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'config:read-result',
            'checkoutId': 'main',
            'ok': true,
            // ConfigService reads a missing `config` on an `ok` reply as a
            // valid EMPTY one, which showed Project Settings an unconfigured
            // project beside a workspace the rest of the demo presents as
            // fully set up — and then refused to let the reviewer fix it.
            'config': kDemoConfig,
          },
        ];

      case 'config:write':
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'config:write-result',
            'checkoutId': 'main',
            'ok': false,
            'errors': <String>[kDemoRefusalText],
          },
        ];

      case 'config:detect-tools':
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'config:detect-tools-result',
            'checkoutId': 'main',
            'tools': <Map<String, Object?>>[],
          },
        ];

      case 'git:diff':
        return <Map<String, Object?>>[_gitDiff(message['path'] as String?)];

      case 'git:list-branches':
        return <Map<String, Object?>>[kDemoGitBranches];

      case 'git:checkout':
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'git:checkout-result',
            'projectId': kDemoProjectId,
            'checkoutId': 'main',
            'branch': message['branch'] as String? ?? kDemoBranch,
            'success': false,
            'error': kDemoRefusalText,
          },
        ];

      case 'git:commit':
        return <Map<String, Object?>>[_gitFailure('git:commit-result')];

      case 'git:discard':
        return <Map<String, Object?>>[
          _gitFailure('git:discard-result', files: message['files']),
        ];

      case 'git:stage':
        return <Map<String, Object?>>[
          _gitFailure('git:stage-result', files: message['files']),
        ];

      case 'git:unstage':
        return <Map<String, Object?>>[
          _gitFailure('git:unstage-result', files: message['files']),
        ];

      case 'file:search':
        return _search(
          query: message['query'] as String? ?? '',
          requestId: requestId ?? '',
          caseSensitive: message['caseSensitive'] == true,
          regex: message['regex'] == true,
          wholeWord: message['wholeWord'] == true,
        );

      case 'command:run':
        final name = message['commandName'] as String? ?? 'command';
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'command:output',
            'projectId': kDemoProjectId,
            'checkoutId': 'main',
            'commandName': name,
            'data': '$kDemoRefusalText\n',
          },
          <String, Object?>{
            'type': 'command:done',
            'projectId': kDemoProjectId,
            'checkoutId': 'main',
            'commandName': name,
            'exitCode': 1,
          },
        ];

      case 'file:upload-start':
        return <Map<String, Object?>>[
          <String, Object?>{
            'type': 'file:upload-result',
            'checkoutId': 'main',
            'requestId': requestId ?? '',
            'ok': false,
            'error': kDemoRefusalCode,
            'message': kDemoRefusalText,
          },
        ];

      default:
        // Fire-and-forget verbs a bridge answers with nothing: focus
        // declarations, resize, stop, cancel-adjacent chatter.
        //
        // `agent:session-action` (the "Revert conversation" button, which
        // renders on every user message in the canned transcripts) lands here
        // too, and is the one arrival that is NOT fire-and-forget: a real
        // bridge answers it with `agent:snapshot`/`agent:transcript-replay`.
        // Nothing the demo can emit reports the refusal — the app consumes no
        // `agent:error` — so silence is the least dishonest answer, and this
        // note is here so the catch-all is not mistaken for coverage.
        return const <Map<String, Object?>>[];
    }
  }

  Map<String, Object?> _sessionResult(
    String? requestId, {
    required bool ok,
    Map<String, Object?>? entry,
  }) => <String, Object?>{
    'type': 'session:result',
    'checkoutId': 'main',
    'requestId': requestId ?? '',
    'ok': ok,
    'session': ?entry,
    if (!ok) ...<String, Object?>{
      'error': kDemoRefusalText,
      'errorCode': kDemoRefusalCode,
    },
  };

  Map<String, Object?>? _entryFor(String? sessionId) {
    for (final entry in _entries) {
      if (entry['id'] == sessionId) return entry;
    }
    return null;
  }

  Map<String, Object?> _fileContent(String? path) {
    // The refusal rides in as CONTENT, never in the envelope's `error` field:
    // `classifyAbMessage` coerces any error-bearing frame to the STATUS tier,
    // and FileService only handles `file:content` on the HEAVY one — so an
    // honest error here would leave the viewer spinning until the user gave up
    // rather than saying why the file is empty.
    final body =
        (path == null ? null : kDemoFileContents[path]) ??
        '$kDemoRefusalText\n\nThis file is not part of the sample project.\n';
    return <String, Object?>{
      'type': 'file:content',
      'projectId': kDemoProjectId,
      'checkoutId': 'main',
      'path': path ?? '',
      'content': body,
      'size': body.length,
      'encoding': 'utf8',
    };
  }

  Map<String, Object?> _gitDiff(String? path) {
    final diff = path == null ? null : kDemoGitDiffContent[path];
    // Counts read back out of the `git:status` fixture rather than restated
    // here. The Git panel draws them twice, one directly above the other — on
    // the file row and in the diff header — and `GitDiffContentMessage`
    // defaults a missing count to 0, which renders as no stat at all beside a
    // row that just claimed +24 -3.
    final stat = path == null ? null : _gitStatusEntry(path);
    return <String, Object?>{
      'type': 'git:diff-content',
      'projectId': kDemoProjectId,
      'checkoutId': 'main',
      'path': path ?? '',
      'diff': ?diff,
      'additions': ?stat?['additions'],
      'deletions': ?stat?['deletions'],
      if (diff == null) 'error': 'Not part of the sample project',
    };
  }

  static Map<String, Object?>? _gitStatusEntry(String path) {
    for (final frame in kDemoDurableFrames) {
      if (frame['type'] != 'git:status') continue;
      for (final f in (frame['files'] as List).cast<Map<String, Object?>>()) {
        if (f['path'] == path) return f;
      }
    }
    return null;
  }

  Map<String, Object?> _gitFailure(String type, {Object? files}) =>
      <String, Object?>{
        'type': type,
        'projectId': kDemoProjectId,
        'checkoutId': 'main',
        'success': false,
        if (files is List) 'files': files.whereType<String>().toList(),
        'error': kDemoRefusalText,
      };

  /// Confirms the terminal the caller asked to start, never the sample one:
  /// `TerminalService` settles its pending tab by id, so a constant reply left
  /// a user-created tab to expire into `exited` 15s later AND re-snapshotted
  /// the sample terminal, erasing everything the script had played into it.
  Map<String, Object?> _terminalStarted(String? terminalId) {
    if (terminalId == null || terminalId == kDemoTerminalId) {
      return kDemoTerminalStarted;
    }
    return <String, Object?>{
      ...kDemoTerminalStarted,
      'terminalId': terminalId,
      // Not the sample terminal's 'agent' — this one is the user's own shell,
      // unless it is the `dev` service being restarted from the Services tab.
      // Answering null there would retype the tab and drop it into the ad-hoc
      // Terminals list, which filters on exactly this field.
      'terminalType': terminalId == kDemoServiceTerminalId ? 'service' : null,
    };
  }

  /// Scrollback for [terminalId]. A tab the demo has no history for gets a
  /// bare prompt rather than the sample terminal's, which `_applySnapshot`
  /// erases the target buffer to write.
  Map<String, Object?> _terminalSnapshot(String? terminalId) {
    if (terminalId == null || terminalId == kDemoTerminalId) {
      return kDemoTerminalSnapshot;
    }
    if (terminalId == kDemoServiceTerminalId) return kDemoServiceSnapshot;
    return <String, Object?>{
      ...kDemoTerminalSnapshot,
      'terminalId': terminalId,
      'scrollback': kDemoShellPrompt,
    };
  }

  /// Echoes typed bytes so the terminal feels attached, then says plainly that
  /// nothing ran when the user presses Enter.
  List<Map<String, Object?>> _terminalEcho(String? terminalId, String? data) {
    if (data == null || data.isEmpty) return const <Map<String, Object?>>[];
    final isEnter = data.contains('\r') || data.contains('\n');
    return <Map<String, Object?>>[
      <String, Object?>{
        'type': 'terminal:output',
        'checkoutId': 'main',
        // The tab the bytes came from: a constant here typed the user's
        // keystrokes into a terminal they were not looking at.
        'terminalId': terminalId ?? kDemoTerminalId,
        'data': isEnter ? '\r\n$kDemoRefusalText\r\n$kDemoShellPrompt' : data,
      },
    ];
  }

  /// A real search over the sample file bodies — cheaper than canning
  /// per-query results, and it keeps the result count honest for whatever the
  /// user types.
  ///
  /// Honours every flag the panel can set. The regex and whole-word toggles
  /// render unconditionally, so ignoring them answered a working pattern with
  /// a confident zero; and one `indexOf` per line under-counted every line
  /// that matched twice, in the totals as well as the list.
  List<Map<String, Object?>> _search({
    required String query,
    required String requestId,
    required bool caseSensitive,
    required bool regex,
    required bool wholeWord,
  }) {
    final matches = <Map<String, Object?>>[];
    final files = <String>{};
    RegExp? pattern;
    if (query.isNotEmpty) {
      final escaped = regex ? query : RegExp.escape(query);
      try {
        pattern = RegExp(
          wholeWord ? '\\b(?:$escaped)\\b' : escaped,
          caseSensitive: caseSensitive,
        );
      } on FormatException {
        // Settled as an empty result rather than reported through the done
        // frame's `error` field, for the reason [_fileContent] documents:
        // `classifyAbMessage` coerces any error-bearing frame to the STATUS
        // tier, and SearchService subscribes to the HEAVY one alone — an
        // honest error here never arrives, so the panel spins until the idle
        // guard gives up on it 12s later and blames the agent.
      }
    }
    if (pattern != null) {
      for (final entry in _fileLines.entries) {
        final lines = entry.value;
        for (var i = 0; i < lines.length; i++) {
          for (final m in pattern.allMatches(lines[i])) {
            // A pattern that can match nothing ('a*') would otherwise report a
            // hit at every column of every line.
            if (m.end == m.start) continue;
            files.add(entry.key);
            matches.add(<String, Object?>{
              'path': entry.key,
              'line': i + 1,
              'column': m.start + 1,
              'lineContent': lines[i],
              'contextBefore': <String>[],
              'contextAfter': <String>[],
            });
          }
        }
      }
    }
    return <Map<String, Object?>>[
      <String, Object?>{
        'type': 'file:search-result',
        'projectId': kDemoProjectId,
        'checkoutId': 'main',
        'requestId': requestId,
        'matches': matches,
      },
      <String, Object?>{
        'type': 'file:search-done',
        'projectId': kDemoProjectId,
        'checkoutId': 'main',
        'requestId': requestId,
        'totalMatches': matches.length,
        'totalFiles': files.length,
        'duration': 4,
        'engine': 'demo',
      },
    ];
  }

  // ── playback ──

  void _enqueue(List<DemoBeat> beats) {
    if (_disposed) return;
    final now = DateTime.now();
    for (final beat in beats) {
      _queue.add(
        _PendingBeat(now.add(beat.at), _beatSeq++, beat.channel, beat.frame),
      );
    }
    _rearm();
  }

  void _enqueueAll(Duration at, List<Map<String, Object?>> frames) {
    if (_disposed || frames.isEmpty) return;
    final due = DateTime.now().add(at);
    for (final frame in frames) {
      _queue.add(_PendingBeat(due, _beatSeq++, 'control', frame));
    }
    _rearm();
  }

  /// Chained single-shot timers, never a periodic one: playback is finite, and
  /// a periodic timer would keep firing after the last beat for as long as the
  /// demo stays open.
  void _rearm() {
    _timer?.cancel();
    _timer = null;
    if (_queue.isEmpty) return;
    _queue.sort((a, b) {
      final byDue = a.due.compareTo(b.due);
      // Enqueue order breaks the tie. `_enqueueAll` stamps every frame of one
      // reply with a single `due`, and those pairs (`file:search-result` then
      // `file:search-done`, `command:output` then `command:done`) carry their
      // meaning in the order alone.
      return byDue != 0 ? byDue : a.seq.compareTo(b.seq);
    });
    final wait = _queue.first.due.difference(DateTime.now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _fire);
  }

  void _fire() {
    _timer = null;
    if (_disposed) return;
    final now = DateTime.now();
    while (_queue.isNotEmpty && !_queue.first.due.isAfter(now)) {
      final beat = _queue.removeAt(0);
      dispatchDecoded(_stamp(beat.frame), beat.channel);
    }
    _rearm();
  }

  /// Plays a canned reply into [sessionId]. Built here rather than in the
  /// script file because the beats have to carry the text the user just typed.
  void _playPromptReply(String sessionId, String text) {
    _enqueue(
      demoPromptReplyBeats(
        sessionId: sessionId,
        turnId: 'demo-live-turn-${_turnSeq++}',
        promptText: text,
      ),
    );
  }

  /// Stops a reply mid-stream. Dropping the queued beats is the load-bearing
  /// half: closing the turn while its deltas are still scheduled would keep
  /// writing into a transcript the user has already stopped.
  void _cancelTurn(String? sessionId, String? turnId) {
    if (sessionId == null || turnId == null) return;
    _queue.removeWhere((beat) => beat.frame['turnId'] == turnId);
    _rearm();
    _enqueueAll(_kReplyDelay, <Map<String, Object?>>[
      <String, Object?>{
        'type': 'agent:turn-end',
        'sessionId': sessionId,
        'turnId': turnId,
        'stopReason': 'cancelled',
      },
    ]);
  }
}

class _PendingBeat {
  _PendingBeat(this.due, this.seq, this.channel, this.frame);
  final DateTime due;
  final int seq;
  final String channel;
  final Map<String, Object?> frame;
}
