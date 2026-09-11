// The badge is the only place a session that is not open can say it has mail,
// and it has to say it on BOTH surfaces that name a session — the drawer row
// and the Recent row. The Handler badge it is modelled on is mounted on the
// first and not the second, so "it works" has to be proven twice.
//
// It is also the way IN to that mail, which is what the last group holds: the
// tap has to reach the sheet for this row's session, and has to do it without
// the row underneath claiming the same tap and switching sessions.
import 'dart:async';

import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/session_bus_inbox.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/recent_sessions/recent_session_row_widget.dart';
import 'package:antgrid/widgets/session_inbox_badge.dart';
import 'package:antgrid/widgets/session_inbox_panel.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _projectId = 'proj-inbox';
const _sessionId = 'sess-inbox';

/// Answers every inbox read with a fixed count, the way a bridge holding that
/// many posts would. Posts are left empty on purpose: the count is what the
/// badge renders, and the provider's contract is that it can outrun the list.
class _CountingChannel implements SessionBusChannel {
  _CountingChannel(this.unread);

  final int unread;
  final _frames = StreamController<Map<String, dynamic>>.broadcast();

  /// How many times this channel was asked to send anything. A row guarded by
  /// the wrong entryId must never build [sessionInboxProvider] at all, so this
  /// stays 0 rather than merely answering a read the guard should have refused.
  int sends = 0;

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    sends++;
    if (message['type'] != 'session-bus:inbox') return;
    _frames.add({
      'type': 'session-bus:inbox:result',
      'requestId': message['requestId'],
      'posts': const <Map<String, dynamic>>[],
      'unread': unread,
      'dropped': 0,
    });
  }

  @override
  Future<void> hydrate(String key, Future<void> Function() run) => run();

  @override
  void unhydrate(String key) {}

  Future<void> dispose() => _frames.close();
}

Finder _count(String label) => find.descendant(
  of: find.byType(SessionInboxBadge),
  matching: find.text(label),
);

Finder get _anyChip => find.descendant(
  of: find.byType(SessionInboxBadge),
  matching: find.byType(AbChip),
);

SessionEntry _session() => const SessionEntry(
  id: _sessionId,
  name: 'Rename the relay epoch',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
);

RecentSessionRow _recentRow() => RecentSessionRow(
  session: _session(),
  origin: const RecentOrigin(
    isLocal: true,
    registrationId: _projectId,
    projectId: _projectId,
    machineUuid: null,
    projectName: 'antgrid',
    deviceName: 'this machine',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  /// The drawer row needs a real project session behind it; the Recent row does
  /// not. Both read the badge through an overridden channel, so neither test
  /// stands up a transport for the bus itself.
  Future<ProviderContainer> containerFor(
    _CountingChannel channel, {
    bool withProjectSession = false,
  }) async {
    addTearDown(channel.dispose);
    final overrides = <Override>[
      selectedRegistrationIdProvider.overrideWithValue(_projectId),
      sessionBusChannelProvider.overrideWithValue(channel),
    ];
    ProjectSession? projectSession;
    if (withProjectSession) {
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      projectSession = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      overrides.add(
        projectSessionProvider.overrideWith((ref, id) async => projectSession!),
      );
    }
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    if (withProjectSession) {
      await container.read(projectSessionProvider(_projectId).future);
    }
    return container;
  }

  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container,
    Widget child, {
    double width = 800,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
          ),
          home: Scaffold(body: SizedBox(width: width, child: child)),
        ),
      ),
    );
    // Three frames, not `pumpEventQueue`: the read answers on a broadcast
    // stream, so the result lands in a microtask that only runs while the
    // tester's clock is being advanced — awaiting the event queue instead
    // parks on a timer nothing is left to fire.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  group('drawer session row', () {
    testWidgets('carries the unread count once the read answers', (
      tester,
    ) async {
      final container = await containerFor(
        _CountingChannel(4),
        withProjectSession: true,
      );
      await pump(
        tester,
        container,
        SessionRow(entryId: _projectId, session: _session()),
        width: 260,
      );

      expect(_count('4'), findsOneWidget);
    });

    testWidgets('shows nothing when the mailbox is empty', (tester) async {
      final container = await containerFor(
        _CountingChannel(0),
        withProjectSession: true,
      );
      await pump(
        tester,
        container,
        SessionRow(entryId: _projectId, session: _session()),
        width: 260,
      );

      expect(find.byType(SessionInboxBadge), findsOneWidget);
      expect(_anyChip, findsNothing);
    });
  });

  group('recent session row', () {
    testWidgets('carries the unread count on the wide layout', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final container = await containerFor(_CountingChannel(2));
      await pump(tester, container, RecentSessionRowWidget(row: _recentRow()));

      expect(_count('2'), findsOneWidget);
      // Cleared inside the body: the framework asserts on a foundation debug
      // variable still set when the test returns, and a tear-down runs later
      // than that check.
      debugDefaultTargetPlatformOverride = null;
    });

    // The narrow layout is a separate subtree with its own badge cluster, so a
    // badge added to the wide one alone would vanish on a phone.
    testWidgets('carries the unread count on the narrow layout', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final container = await containerFor(_CountingChannel(7));
      await pump(
        tester,
        container,
        RecentSessionRowWidget(row: _recentRow()),
        width: 400,
      );

      expect(_count('7'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows nothing when the mailbox is empty', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final container = await containerFor(_CountingChannel(0));
      await pump(tester, container, RecentSessionRowWidget(row: _recentRow()));

      expect(find.byType(SessionInboxBadge), findsOneWidget);
      expect(_anyChip, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('badge contract', () {
    testWidgets(
      'the count is neither the unread tone nor accent — only textSecondary',
      (tester) async {
        final container = await containerFor(_CountingChannel(3));
        await pump(
          tester,
          container,
          const SessionInboxBadge(entryId: _projectId, sessionId: _sessionId),
        );

        final chip = tester.widget<AbChip>(
          find.descendant(
            of: find.byType(SessionInboxBadge),
            matching: find.byType(AbChip),
          ),
        );
        final palette = tester.element(find.byType(SessionInboxBadge)).antgrid;
        // `unread` already paints the leading dot's blue for an answer THIS
        // session's agent wrote; `accent` is spoken for by the handler badge's
        // waiting-on-the-user question. Bus mail is neither, and two counts in
        // one row that clear on different actions must not share a colour.
        expect(chip.color, palette.textSecondary);
        expect(chip.color, isNot(palette.unread));
        expect(chip.color, isNot(palette.accent));
      },
    );

    testWidgets(
      'a row for another project renders nothing without reading its channel',
      (tester) async {
        final channel = _CountingChannel(5);
        final container = await containerFor(channel);
        await pump(
          tester,
          container,
          const SessionInboxBadge(
            entryId: 'other-project',
            sessionId: _sessionId,
          ),
        );

        expect(find.byType(SessionInboxBadge), findsOneWidget);
        expect(_anyChip, findsNothing);
        // Proves the entryId guard fires BEFORE sessionInboxProvider is ever
        // watched — not merely that it answers with zero.
        expect(channel.sends, 0);
      },
    );
  });

  group('opening the mail', () {
    /// The sheet route needs a frame to push and one for its transition.
    Future<void> settleRoute(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('a tap opens the sheet for THIS row\'s session', (
      tester,
    ) async {
      final container = await containerFor(_CountingChannel(3));
      await pump(
        tester,
        container,
        const SessionInboxBadge(entryId: _projectId, sessionId: _sessionId),
      );

      await tester.tap(find.byType(SessionInboxBadge));
      await settleRoute(tester);

      // The session id is the assertion, not merely that something opened: the
      // badge's whole reason to be the entry point is that it can speak for a
      // session nothing else on screen is scoped to.
      expect(
        tester.widget<SessionInboxPanel>(find.byType(SessionInboxPanel))
            .sessionId,
        _sessionId,
      );
    });

    // Mounted inside a real row, because the hazard is the row and not the
    // badge: a session row is itself tappable, and a badge that let the tap
    // through would switch sessions on the way to reading a sibling's mail.
    testWidgets('the row underneath does not also take the tap', (
      tester,
    ) async {
      final container = await containerFor(
        _CountingChannel(4),
        withProjectSession: true,
      );
      await pump(
        tester,
        container,
        SessionRow(entryId: _projectId, session: _session()),
        width: 260,
      );

      await tester.tap(find.byType(SessionInboxBadge));
      await settleRoute(tester);

      expect(find.byType(SessionInboxPanel), findsOneWidget);
    });
  });
}
