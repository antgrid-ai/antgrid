// Re-attach behaviour of TerminalService: the seq cutoff around a re-drive,
// and the bytes a snapshot is allowed to put on the engine.
//
// The agent DROPS terminal output while it is suppressed (peer gone, app
// backgrounded, remote access off) but keeps bumping its per-terminal seq, so a
// tab that was already on screen when the stream went away has no other way to
// learn what it missed. The pull's own bookkeeping is what these cases pin: a
// cutoff kept across a re-drive filters the live output of a PTY that respawned
// unwitnessed, and a snapshot that erases more than it can restore takes the
// user's own history with it.
//
// The engine cases are gated on native availability: a host without the
// prebuilt libghostty-vt reports them SKIPPED rather than failing — and never
// passing, which is what a bare early return would have made it.

import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

/// True when the native VT is missing, having marked the current test skipped.
///
/// Skipped rather than quietly returned from: a bare early return makes a host
/// with no prebuilt libghostty-vt report a green suite that asserted nothing.
bool _skipWithoutNative() {
  if (_hasNative()) return false;
  markTestSkipped('native VT unavailable');
  return true;
}

bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> makeSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    )..setActiveCheckouts({'main'});
  }

  /// Seeds one running tab named `a` and settles the discovery pull.
  Future<void> seedTabA(FakeAgentTransport t) async {
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {'id': 'a', 'terminalId': 'a', 'name': 'a', 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'the seq cutoff is dropped before the re-attach requests go out',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await seedTabA(t);
      final tab = session.terminalService.currentState.tabs['a']!;

      t.emit('terminal:snapshot', {
        'terminalId': 'a',
        'scrollback': '',
        'seq': 50,
      });
      await Future<void>.delayed(Duration.zero);

      // Baseline: the cutoff is armed and filtering.
      t.emit('terminal:output', {
        'terminalId': 'a',
        'data': 'STALE',
        'seq': 10,
      });
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, isNot(contains('STALE')));

      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);

      // The respawned PTY restarts its counter at 1, so its first frames sit
      // below the old cutoff and must not wait on the reply to be rendered.
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'LIVE', 'seq': 11});
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, contains('LIVE'));

      await session.close();
    },
  );

  test(
    'a snapshot pull asks for history only while the engine is empty',
    () async {
      if (_skipWithoutNative()) return;
      // The agent's history blob ERASES before it paints, so this flag decides
      // between two losses. Asked for against an engine that already holds the
      // user's scrollback, it destroys thousands of lines to put back the few
      // hundred the agent keeps. Not asked for against an empty one, a scrolling
      // build log — the worktree setup transcript above all — comes back as its
      // last few rows with nothing above them.
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await seedTabA(t);

      // Discovery: the tab's engine was built moments ago and holds nothing.
      final discovery = t.requests.firstWhere(
        (r) => r.method == 'terminal.snapshot',
      );
      expect(discovery.params?['history'], isTrue);

      t.emit('terminal:output', {
        'terminalId': 'a',
        'data': 'painted',
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);

      final before = t.requests.length;
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);

      final reattach = t.requests
          .skip(before)
          .firstWhere((r) => r.method == 'terminal.snapshot');
      expect(reattach.params?['history'], isFalse);

      await session.close();
    },
  );

  test(
    'a snapshot request that is never answered leaves no cutoff behind',
    () async {
      if (_skipWithoutNative()) return;
      // A `requestHandler` that never completes is what an unknown terminal
      // id or a send dropped in a keyless window looks like now — the RPC
      // stays pending rather than failing outright. The clear has to be
      // unconditional for this case to render at all.
      final t = FakeAgentTransport();
      t.requestHandler = (_, _) => Completer<Map<String, dynamic>>().future;
      final session = await makeSession(t);
      await seedTabA(t);
      final tab = session.terminalService.currentState.tabs['a']!;

      t.emit('terminal:snapshot', {
        'terminalId': 'a',
        'scrollback': '',
        'seq': 900,
      });
      await Future<void>.delayed(Duration.zero);

      final before = t.requests.length;
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(
        t.requests.skip(before).where((r) => r.method == 'terminal.snapshot'),
        hasLength(1),
      );

      t.emit('terminal:output', {
        'terminalId': 'a',
        'data': 'REBORN',
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, contains('REBORN'));

      await session.close();
    },
  );

  test(
    'a snapshot pull refused as an unknown terminal drops the tab',
    () async {
      if (_skipWithoutNative()) return;
      // The agent keeps no record of the id (a transcript from before a bridge
      // restart), so nothing will ever paint the tab: every reconnect would
      // re-pull and be refused again, and the pane sits blank under a live
      // dot. The refusal names the tab, and the tab goes.
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await seedTabA(t);
      expect(session.terminalService.currentState.tabs.keys, ['a']);

      t.emit('control:result', {
        'ok': false,
        'verb': 'terminal:snapshot:request',
        'terminalId': 'a',
        'error': {'code': 'UNKNOWN_TERMINAL', 'message': 'no terminal a'},
      });
      await Future<void>.delayed(Duration.zero);

      expect(session.terminalService.currentState.tabs, isEmpty);
      expect(session.terminalService.currentState.activeTerminalId, isNull);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:stop'),
        isEmpty,
        reason: 'there is nothing on the agent to stop',
      );

      // Not a delete: the agent reporting it running again is a real terminal.
      await seedTabA(t);
      expect(session.terminalService.currentState.tabs.keys, ['a']);

      await session.close();
    },
  );

  test('a legacy snapshot does not stack a copy per attach', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    for (var i = 0; i < 60; i++) {
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'HIST-$i\r\n'});
    }
    await Future<void>.delayed(Duration.zero);

    // An older agent answers with a RAW BYTE TAIL, capped at ten thousand
    // characters — several screens. Drawn past the bottom row it scrolls its
    // own opening lines into the buffer above, so an erase that stops at the
    // screen leaves one copy behind on every attach. The re-attach fires on
    // every focus resume, so "one copy per attach" is unbounded.
    final tail = List.generate(40, (i) => 'TAIL-$i').join('\r\n');
    for (var attach = 0; attach < 3; attach++) {
      t.emit('terminal:snapshot', {
        'terminalId': 'a',
        'scrollback': tail,
        'seq': 5 + attach,
      });
      await Future<void>.delayed(Duration.zero);
    }

    expect(tab.ghostty.plainText, contains('TAIL-39'));
    expect('TAIL-0\n'.allMatches(tab.ghostty.plainText).length, 1);

    await session.close();
  });

  test('a composed snapshot is applied verbatim onto the screen its preamble '
      'selects', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    t.emit('terminal:output', {'terminalId': 'a', 'data': 'HISTORY-LINE\r\n'});
    await Future<void>.delayed(Duration.zero);

    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback': '\x1b[?1049l\x1b[r\x1b[2J\x1b[H\x1b[0m\x1b[?1049hTAIL-ROWS',
      'seq': 7,
      'composed': true,
    });
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, contains('TAIL-ROWS'));
    expect(tab.ghostty.plainText, isNot(contains('HISTORY-LINE')));

    // Back on the primary buffer, the blob's own erase is what the user sees —
    // not the pre-departure content the app would otherwise have kept.
    t.emit('terminal:output', {'terminalId': 'a', 'data': '\x1b[?1049l'});
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, isNot(contains('HISTORY-LINE')));

    await session.close();
  });

  test("a composed snapshot never erases the app's scrollback", () async {
    if (_skipWithoutNative()) return;
    // The blob repaints one screen and carries no history, so an erase that
    // reached past the screen would destroy the user's own — ten thousand lines
    // of it — with nothing on this path able to put it back.
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    for (var i = 0; i < 60; i++) {
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'HIST-$i\r\n'});
    }
    await Future<void>.delayed(Duration.zero);

    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback': '\x1b[?1049l\x1b[r\x1b[2J\x1b[H\x1b[0mSCREEN-ROW',
      'seq': 5,
      'composed': true,
    });
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, contains('HIST-0'));
    expect(tab.ghostty.plainText, contains('SCREEN-ROW'));

    await session.close();
  });

  test("a warm engine refuses another device's cold history blob", () async {
    if (_skipWithoutNative()) return;
    // A snapshot reply is published on the project bus, so a phone's FIRST
    // attach is answered to every client on that project. The cold blob leads
    // with `3J`, which would erase the desktop's own scrollback -- the exact
    // loss the warm preamble omits `3J` to avoid. The frame is labelled, and a
    // client whose engine is already painted drops it.
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    // This client's OWN cold request is answered first, which is what
    // makes it warm: the claim is spent, so a later history blob can only
    // be someone else's. Without this the tab is still awaiting its own
    // answer and would rightly accept the next history blob it sees.
    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback': '\x1b[?1049l\x1b[r\x1b[0m\x1b[2J\x1b[HREADY',
      'seq': 1,
      'composed': true,
    });
    await Future<void>.delayed(Duration.zero);

    for (var i = 0; i < 60; i++) {
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'MINE-$i\r\n'});
    }
    await Future<void>.delayed(Duration.zero);

    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback':
          '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[HTHEIR-COLD-SCREEN',
      'seq': 9,
      'composed': true,
      'history': true,
    });
    await Future<void>.delayed(Duration.zero);

    // Untouched: history intact, and the other device's screen never painted.
    expect(tab.ghostty.plainText, contains('MINE-0'));
    expect(tab.ghostty.plainText, isNot(contains('THEIR-COLD-SCREEN')));

    await session.close();
  });

  test('a cold client still gets the history it asked for', () async {
    if (_skipWithoutNative()) return;
    // The refusal above must not swallow this client's OWN answer — but on a
    // correlated RPC that claim ("did I ask for history") rides the
    // `requestId` itself, so no other client's blob can spend it and the
    // scenario has nothing left to prove on that arm. It is
    // [_awaitingHistoryIds]'s regression test instead: force the
    // FALLBACK the same way an old bridge would, with `E_UNKNOWN_METHOD` on
    // the discovery request, then replay the original story over the legacy
    // message the fallback re-issues. A snapshot request goes out while the
    // engine is empty, live output paints it during the round trip -- routine
    // on a busy terminal -- and the reply then finds a painted engine. It is
    // still the answer to OUR request, and dropping it would leave the cold
    // attach with a screen and no history.
    final t = FakeAgentTransport();
    t.requestHandler = (_, _) =>
        throw RpcException('E_UNKNOWN_METHOD', 'unknown method');
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    // A fresh tab is cold, so the discovery request claimed history — over
    // the legacy message the fallback re-issued once the RPC came back
    // `E_UNKNOWN_METHOD`.
    final request = t.sent.lastWhere(
      (m) => m['type'] == 'terminal:snapshot:request',
    );
    expect(request['history'], isTrue);

    // Output lands before the reply does.
    t.emit('terminal:output', {'terminalId': 'a', 'data': 'LIVE-BYTE\r\n'});
    await Future<void>.delayed(Duration.zero);

    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback':
          '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[HMY-COLD-SCREEN',
      'seq': 9,
      'composed': true,
      'history': true,
    });
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, contains('MY-COLD-SCREEN'));

    // The claim is spent: a SECOND history blob (another device's) now finds a
    // painted engine with nothing outstanding, and is refused.
    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback':
          '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[HTHEIR-COLD-SCREEN',
      'seq': 10,
      'composed': true,
      'history': true,
    });
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, contains('MY-COLD-SCREEN'));
    expect(tab.ghostty.plainText, isNot(contains('THEIR-COLD-SCREEN')));

    await session.close();
  });

  test('live output during the round trip does not lose the history', () async {
    if (_skipWithoutNative()) return;
    // The RPC arm's version of the story above, and the reason a pull is
    // RETIRED by live output but not DISOWNED by it. Bytes arriving mid-flight
    // mean the pane is visibly alive, so no failure verdict is owed -- but the
    // scrollback that pull is carrying is exactly what a cold attach is still
    // waiting for, and a busy terminal is where both are most likely. The
    // agent's own pane is the busiest one there is.
    final t = FakeAgentTransport();
    final held = Completer<Map<String, dynamic>>();
    t.requestHandler = (method, params) =>
        method == 'terminal.snapshot' ? held.future : <String, dynamic>{};
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    expect(
      t.requests.where((r) => r.method == 'terminal.snapshot'),
      hasLength(1),
    );

    t.emit('terminal:output', {
      'terminalId': 'a',
      'data': 'LIVE-BYTE\r\n',
      'seq': 5,
    });
    await Future<void>.delayed(Duration.zero);

    held.complete({
      'snapshot': {
        'terminalId': 'a',
        'scrollback':
            '[?1049l[r[0m[3J[2J[HMY-COLD-SCREEN',
        'seq': 9,
        'composed': true,
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, contains('MY-COLD-SCREEN'));

    await session.close();
  });

  test('an old bridge is learned from a terminal that is streaming', () async {
    if (_skipWithoutNative()) return;
    // The fallback verdict is about the BRIDGE, not about the pull that
    // discovered it. Behind the generation guard, a terminal busy enough to
    // have moved on would spend a whole round trip per pull forever without
    // learning the peer cannot answer.
    final t = FakeAgentTransport();
    final held = Completer<Map<String, dynamic>>();
    t.requestHandler = (method, params) =>
        method == 'terminal.snapshot' ? held.future : <String, dynamic>{};
    final session = await makeSession(t);
    await seedTabA(t);

    // Retires the pull's bound; the reply is still owned.
    t.emit('terminal:output', {
      'terminalId': 'a',
      'data': 'LIVE-BYTE\r\n',
      'seq': 5,
    });
    await Future<void>.delayed(Duration.zero);

    held.completeError(RpcException('E_UNKNOWN_METHOD', 'no such method'));
    await Future<void>.delayed(Duration.zero);

    // The next pull skips the RPC entirely rather than re-discovering it.
    final rpcsBefore = t.requests
        .where((r) => r.method == 'terminal.snapshot')
        .length;
    session.terminalService.retryAttach('a');
    await Future<void>.delayed(Duration.zero);
    expect(
      t.requests.where((r) => r.method == 'terminal.snapshot'),
      hasLength(rpcsBefore),
    );
    expect(
      t.sent.where((m) => m['type'] == 'terminal:snapshot:request'),
      isNotEmpty,
    );

    await session.close();
  });

  test('the pull names the checkout it was built for', () async {
    if (_skipWithoutNative()) return;
    // The bridge resolves a terminal id inside ONE checkout's runtime, and an
    // isolated session's agent pane carries the same id as main's. A pull that
    // named the wrong checkout is not answered with an error the pane could
    // show — it is answered with the other checkout's screen.
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);

    final isolated = TerminalService.fromSession(session, checkoutId: 'wt-1');
    addTearDown(isolated.dispose);
    t.emit('agent:status', {
      'projectId': 'p',
      'checkoutId': 'wt-1',
      'terminals': [
        {'id': 'a', 'terminalId': 'a', 'name': 'a', 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    final pulls = t.requests.where((r) => r.method == 'terminal.snapshot');
    expect(pulls.first.params?['checkoutId'], 'main');
    expect(pulls.last.params?['checkoutId'], 'wt-1');

    await session.close();
  });

  test('an RPC reply arms the cutoff its seq names', () async {
    if (_skipWithoutNative()) return;
    // The cutoff is what filters the output the agent dropped while suppressed,
    // and on this arm it can only come off the correlated result — no
    // `terminal:snapshot` frame reaches the bus at all. Left unarmed, every
    // stale frame the agent buffered repaints on top of the screen just pulled.
    final t = FakeAgentTransport();
    t.requestHandler = (method, params) => method == 'terminal.snapshot'
        ? <String, dynamic>{
            'snapshot': {
              'terminalId': 'a',
              'scrollback': '',
              'seq': 50,
              'composed': true,
            },
          }
        : <String, dynamic>{};
    final session = await makeSession(t);
    await seedTabA(t);
    await Future<void>.delayed(Duration.zero);
    final tab = session.terminalService.currentState.tabs['a']!;

    t.emit('terminal:output', {
      'terminalId': 'a',
      'data': 'STALE',
      'seq': 10,
    });
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, isNot(contains('STALE')));

    t.emit('terminal:output', {
      'terminalId': 'a',
      'data': 'FRESH',
      'seq': 51,
    });
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, contains('FRESH'));

    await session.close();
  });

  test('the fallback verdict does not survive a re-establishment', () async {
    if (_skipWithoutNative()) return;
    // A stream re-attach can land on a bridge that has since been upgraded, or
    // on a different machine entirely. A verdict kept across it pins the client
    // to the uncorrelated legacy message — no requestId, no timeout, no error
    // path — for the rest of its life, and nothing would ever re-test it.
    final t = FakeAgentTransport();
    var oldBridge = true;
    t.requestHandler = (method, params) {
      if (method != 'terminal.snapshot') return <String, dynamic>{};
      if (oldBridge) throw RpcException('E_UNKNOWN_METHOD', 'no such method');
      return <String, dynamic>{'snapshot': null};
    };
    final session = await makeSession(t);
    await seedTabA(t);
    await Future<void>.delayed(Duration.zero);

    // Learned: the next pull would skip the RPC.
    final learned = t.requests
        .where((r) => r.method == 'terminal.snapshot')
        .length;
    session.terminalService.retryAttach('a');
    await Future<void>.delayed(Duration.zero);
    expect(
      t.requests.where((r) => r.method == 'terminal.snapshot'),
      hasLength(learned),
    );

    oldBridge = false;
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);
    expect(
      t.requests.where((r) => r.method == 'terminal.snapshot').length,
      greaterThan(learned),
    );

    await session.close();
  });

  test('an RPC pull never claims the history a broadcast would spend', () async {
    if (_skipWithoutNative()) return;
    // The "did I ask for history" claim is the legacy arm's alone: on a
    // correlated reply the requestId carries it. Claiming it here too would
    // hand the first fanned-out history blob — another device's cold attach,
    // leading with `3J` — the one exemption that lets it erase this client's
    // scrollback, while our own answer is still on the wire.
    final t = FakeAgentTransport();
    final held = Completer<Map<String, dynamic>>();
    t.requestHandler = (method, params) =>
        method == 'terminal.snapshot' ? held.future : <String, dynamic>{};
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    for (var i = 0; i < 60; i++) {
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'MINE-$i\r\n'});
    }
    await Future<void>.delayed(Duration.zero);

    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback':
          '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[HTHEIR-COLD-SCREEN',
      'seq': 9,
      'composed': true,
      'history': true,
    });
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, contains('MINE-0'));
    expect(tab.ghostty.plainText, isNot(contains('THEIR-COLD-SCREEN')));

    // Ours still lands: the refusal above spent nothing.
    held.complete({
      'snapshot': {
        'terminalId': 'a',
        'scrollback':
            '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[HMY-COLD-SCREEN',
        'seq': 10,
        'composed': true,
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, contains('MY-COLD-SCREEN'));

    await session.close();
  });

  test('applying a composed snapshot twice is idempotent', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    Map<String, dynamic> composed(int seq) => {
      'terminalId': 'a',
      'scrollback': '\x1b[?1049l\x1b[r\x1b[2J\x1b[H\x1b[0m\x1b[?1049hPANE-ROW',
      'seq': seq,
      'composed': true,
    };

    t.emit('terminal:snapshot', composed(7));
    await Future<void>.delayed(Duration.zero);
    final once = tab.ghostty.plainText;

    t.emit('terminal:snapshot', composed(8));
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, once);

    // The primary buffer must not accumulate a second copy either — that is
    // what would turn a repeated re-pull into a stack of screens.
    t.emit('terminal:output', {'terminalId': 'a', 'data': '\x1b[?1049l'});
    await Future<void>.delayed(Duration.zero);
    expect('PANE-ROW'.allMatches(tab.ghostty.plainText), isEmpty);

    await session.close();
  });

  // The PTY's geometry is invalidated by exactly the two events the seq cutoff
  // is: a re-drive and a same-id respawn. The driver re-sends `terminal:resize`
  // only when its computed grid differs from the last size it believes the PTY
  // received, so neither event has any other way to reach it — the panel is
  // not moving, so the wrapper keeps computing the same grid and the gate stays
  // shut for as long as the terminal is on screen.
  test('a re-drive retires the geometry the driver booked', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final before = session.terminalService.currentState.tabs['a']!.sizeEpoch;

    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    expect(
      session.terminalService.currentState.tabs['a']!.sizeEpoch,
      greaterThan(before),
      reason: 'a resize sent while the stream was away vanished unreported',
    );

    await session.close();
  });

  test('a same-id respawn retires the geometry the driver booked', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final before = session.terminalService.currentState.tabs['a']!.sizeEpoch;

    // A fresh PTY on a known id. Its geometry is the bridge's, not whatever
    // the driver had sent the process that just died — `lastDriverGeometry` if
    // any terminal has resized in that bridge process, 80x24 (used here) if
    // none has.
    t.emit('terminal:started', {
      'terminalId': 'a',
      'shell': 'bash',
      'cols': 80,
      'rows': 24,
    });
    await Future<void>.delayed(Duration.zero);

    final tab = session.terminalService.currentState.tabs['a']!;
    expect(tab.cols, 80);
    expect(tab.sizeEpoch, greaterThan(before));

    await session.close();
  });
}
