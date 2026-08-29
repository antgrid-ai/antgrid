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

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

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
    );
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
      t.clearSent();
      await seedTabA(t);

      // Discovery: the tab's engine was built moments ago and holds nothing.
      final discovery = t.sent.firstWhere(
        (m) => m['type'] == 'terminal:snapshot:request',
      );
      expect(discovery['history'], isTrue);

      t.emit('terminal:output', {
        'terminalId': 'a',
        'data': 'painted',
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);

      t.clearSent();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);

      final reattach = t.sent.firstWhere(
        (m) => m['type'] == 'terminal:snapshot:request',
      );
      expect(reattach['history'], isFalse);

      await session.close();
    },
  );

  test(
    'a snapshot request that is never answered leaves no cutoff behind',
    () async {
      if (_skipWithoutNative()) return;
      // The fake transport records the request and never replies, which is what
      // an unknown terminal id or a send in a keyless window looks like from
      // here. The clear has to be unconditional for this case to render at all.
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await seedTabA(t);
      final tab = session.terminalService.currentState.tabs['a']!;

      t.emit('terminal:snapshot', {
        'terminalId': 'a',
        'scrollback': '',
        'seq': 900,
      });
      await Future<void>.delayed(Duration.zero);

      t.clearSent();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:snapshot:request'),
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
    // The refusal above must not swallow this client's OWN answer. A snapshot
    // request goes out while the engine is empty, live output paints it during
    // the round trip -- routine on a busy terminal -- and the reply then finds
    // a painted engine. It is still the answer to OUR request, and dropping it
    // would leave the cold attach with a screen and no history.
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await seedTabA(t);
    final tab = session.terminalService.currentState.tabs['a']!;

    // A fresh tab is cold, so the discovery request claimed history.
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
}
