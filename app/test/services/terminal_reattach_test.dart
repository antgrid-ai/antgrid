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
// prebuilt libghostty-vt no-ops rather than failing.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

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
      if (!_hasNative()) return; // native VT unavailable — no-op.
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
    'a snapshot request that is never answered leaves no cutoff behind',
    () async {
      if (!_hasNative()) return; // native VT unavailable — no-op.
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
    if (!_hasNative()) return; // native VT unavailable — no-op.
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
    if (!_hasNative()) return; // native VT unavailable — no-op.
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
    if (!_hasNative()) return; // native VT unavailable — no-op.
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

  test('applying a composed snapshot twice is idempotent', () async {
    if (!_hasNative()) return; // native VT unavailable — no-op.
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
