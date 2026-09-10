// The Inbox is a tab that exists only while the session has a mailbox, and
// three surfaces render the tab list: the desktop strip, the phone's bottom nav
// and the agent bar's workspace rail. Nothing else in the suite iterates
// WorkspaceView.values, so a fourth condition creeping into one of those three
// would ship green — which is what the agreement test below is for.
import 'dart:async';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/providers/session_bus_inbox.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/mobile_bottom_nav.dart';
import 'package:antgrid/widgets/session_inbox_panel.dart';
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _sessionId = 's1';

class _FakeChannel implements SessionBusChannel {
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async => sent.add(message);

  @override
  Future<void> hydrate(String key, Future<void> Function() run) => run();

  @override
  void unhydrate(String key) {}

  void emit(Map<String, dynamic> frame) => _frames.add(frame);

  Future<void> dispose() => _frames.close();

  int get reads => sent.where((m) => m['type'] == 'session-bus:inbox').length;

  String get lastRequestId =>
      sent.lastWhere((m) => m['type'] == 'session-bus:inbox')['requestId']
          as String;
}

Map<String, dynamic> _post(String messageId) => {
  'messageId': messageId,
  'threadId': 't-1',
  'contextId': 'ctx-1',
  'at': 1700000000000,
  'from': {
    'machineId': 'm-other',
    'projectId': 'p-other',
    'sessionId': 's-other',
  },
  'summary': 'same 401 on token refresh?',
  'text': const <String>['line one'],
  'artifacts': const <Map<String, dynamic>>[],
};

/// Pumps [child] against a fake bus channel and a focused session.
///
/// `activeSessionIdProvider` is overridden with a pre-seeded base controller,
/// as its own doc invites: the production notifier's write guard reads the
/// project's live session list, which no widget test stands up.
Future<_FakeChannel> _pump(WidgetTester tester, Widget child) async {
  final channel = _FakeChannel();
  addTearDown(channel.dispose);
  final container = ProviderContainer(
    overrides: [
      sessionBusChannelProvider.overrideWithValue(channel),
      activeSessionIdProvider.overrideWith(
        () => ValueController<String?>(_sessionId),
      ),
      // The rail renders nothing without a published workspace to reveal.
      workspaceMenuControlProvider.overrideWith(
        () => ValueController<WorkspaceMenuControl?>((
          active: WorkspaceView.files,
          reveal: (_) {},
        )),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return channel;
}

/// Answers the mailbox read the surface under test made on hydration.
Future<void> _answerRead(
  WidgetTester tester,
  _FakeChannel channel, {
  required int unread,
  int dropped = 0,
}) async {
  channel.emit({
    'type': 'session-bus:inbox:result',
    'requestId': channel.lastRequestId,
    'posts': [for (var i = 0; i < unread; i++) _post('m$i')],
    'dropped': dropped,
    'unread': unread,
  });
  await tester.pumpAndSettle();
}

/// The bridge's unsolicited arrival push — no request behind it.
Future<void> _pushUnread(
  WidgetTester tester,
  _FakeChannel channel, {
  required int unread,
}) async {
  channel.emit({
    'type': 'session-bus:unread',
    'sessionId': _sessionId,
    'unread': unread,
    'dropped': 0,
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the tab is absent until the session has bus activity', (
    tester,
  ) async {
    final channel = await _pump(
      tester,
      WorkspaceTabBar(selected: WorkspaceView.files, onSelected: (_) {}),
    );

    // An empty mailbox is not a mailbox: a tab standing there with nothing
    // behind it is the thing this rule exists to prevent.
    await _answerRead(tester, channel, unread: 0);
    expect(find.text('Inbox'), findsNothing);

    await _pushUnread(tester, channel, unread: 2);
    expect(find.text('Inbox'), findsOneWidget);
  });

  // Once the tab is up it stays up, because the read that empties the mailbox
  // is the AGENT's and can land at any moment — including while the user is
  // part-way through a thread on that tab.
  testWidgets('the tab survives the agent emptying the mailbox', (
    tester,
  ) async {
    final channel = await _pump(
      tester,
      WorkspaceTabBar(selected: WorkspaceView.files, onSelected: (_) {}),
    );

    await _answerRead(tester, channel, unread: 1);
    expect(find.text('Inbox'), findsOneWidget);

    await _pushUnread(tester, channel, unread: 0);
    expect(find.text('Inbox'), findsOneWidget);
  });

  // The whole point of the unsolicited push: several surfaces share one count
  // without a request each behind them.
  testWidgets('the badge moves on a pushed update with no new read', (
    tester,
  ) async {
    final channel = await _pump(tester, const _BadgedTabBar());
    await _answerRead(tester, channel, unread: 1);
    expect(find.text('1'), findsOneWidget);
    final readsBefore = channel.reads;

    await _pushUnread(tester, channel, unread: 4);

    expect(find.text('4'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(channel.reads, readsBefore);
  });

  testWidgets('every surface that lists tabs agrees the Inbox is not there', (
    tester,
  ) async {
    await _pump(tester, const _AllThreeSurfaces());

    expect(find.text('Inbox'), findsNothing);
    // The three surfaces are present and listing, so the absence above is
    // three agreeing answers rather than three widgets that failed to build.
    expect(find.byType(WorkspaceTabBar), findsOneWidget);
    expect(find.byType(MobileBottomNav), findsOneWidget);
    expect(find.byType(WorkspaceMenuPanel), findsOneWidget);
    expect(find.text('Handler'), findsNWidgets(3));
  });

  testWidgets('every surface that lists tabs agrees the Inbox is there', (
    tester,
  ) async {
    final channel = await _pump(tester, const _AllThreeSurfaces());

    await _answerRead(tester, channel, unread: 3);

    expect(find.text('Inbox'), findsNWidgets(3));
  });

  group('the mailbox', () {
    testWidgets('lists an unread post with its sender', (tester) async {
      final channel = await _pump(tester, const SessionInboxPanel());
      await _answerRead(tester, channel, unread: 1);

      expect(find.text('same 401 on token refresh?'), findsOneWidget);
      expect(find.text('p-other · s-other'), findsOneWidget);
    });

    // The marking read is the AGENT's: a human glancing at this tab must not
    // spend a post the agent has not been handed, or it vanishes unseen. The
    // app has no marking verb at all, and this is what keeps it that way.
    testWidgets('reading the panel sends nothing but the peek', (tester) async {
      final channel = await _pump(tester, const SessionInboxPanel());
      await _answerRead(tester, channel, unread: 2);

      expect(
        channel.sent.map((m) => m['type']).toSet(),
        {'session-bus:inbox'},
      );
    });

    // A LIFETIME total on the store, so it must not be worded as a delta —
    // "since you last looked" would re-accuse the budget of the same posts on
    // every visit.
    testWidgets('the dropped tally is stated as a running total', (
      tester,
    ) async {
      final channel = await _pump(tester, const SessionInboxPanel());
      await _answerRead(tester, channel, unread: 1, dropped: 2);

      expect(
        find.text(
          '2 posts have been discarded for this session against its budget.',
        ),
        findsOneWidget,
      );
    });
  });
}

/// The strip wired to the badge map the way `WorkspaceShell` wires it, so the
/// count under test is the one the tab would really carry.
class _BadgedTabBar extends ConsumerWidget {
  const _BadgedTabBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) => WorkspaceTabBar(
    selected: WorkspaceView.files,
    onSelected: (_) {},
    badges: ref.watch(workspaceBadgesProvider),
  );
}

/// The desktop strip, the phone's nav and the agent bar's rail in one tree, so
/// a disagreement between them is a single failing expectation.
class _AllThreeSurfaces extends StatelessWidget {
  const _AllThreeSurfaces();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WorkspaceTabBar(selected: WorkspaceView.files, onSelected: (_) {}),
        MobileBottomNav(selected: WorkspaceView.files, onSelected: (_) {}),
        const Expanded(
          child: SingleChildScrollView(child: WorkspaceMenuPanel()),
        ),
      ],
    );
  }
}
