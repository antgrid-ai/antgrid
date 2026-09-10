// The Directory, §10.2's surface for "who else is working on this repository".
//
// Driven through a fake bus channel rather than a transport: what these pin is
// how the panel READS an answer — which half of it is local, and that the
// far side's word about whether a session can reply is the word rendered.
import 'dart:async';

import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/providers/session_bus_inbox.dart';
import 'package:antgrid/widgets/session_directory_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _sessionId = 's-me';

class _FakeChannel implements SessionBusChannel {
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async => sent.add(message);

  @override
  Future<void> hydrate(String key, Future<void> Function() run) async {}

  @override
  void unhydrate(String key) {}

  void emit(Map<String, dynamic> frame) => _frames.add(frame);

  Future<void> dispose() => _frames.close();

  String get directoryRequestId =>
      sent.firstWhere(
            (m) => m['type'] == 'session-bus:directory',
          )['requestId']
          as String;
}

Map<String, dynamic> _row({
  required String sessionId,
  required String title,
  String? machineId,
  String? machineLabel,
  bool canReply = true,
  String activity = 'running',
  String? branch,
}) => {
  'machineId': machineId,
  'machineLabel': ?machineLabel,
  'projectId': 'p-1',
  'sessionId': sessionId,
  'title': title,
  'branch': branch,
  'activity': activity,
  'workStatus': 'working',
  'lastActiveAt': DateTime.now().millisecondsSinceEpoch,
  'canReply': canReply,
};

Future<_FakeChannel> _pump(WidgetTester tester) async {
  final channel = _FakeChannel();
  addTearDown(channel.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionBusChannelProvider.overrideWithValue(channel)],
      child: const MaterialApp(
        home: Scaffold(body: SessionDirectoryPanel(sessionId: _sessionId)),
      ),
    ),
  );
  await tester.pump();
  return channel;
}

/// The read's own completion runs on the REAL event loop — the frame arrives on
/// a stream and the answer is a future with a timeout on it — so [runAsync] is
/// what lets it land; a `pump` alone only advances the fake clock and leaves
/// the panel reading as though the bridge never answered.
///
/// Never `pumpAndSettle`: the loading state is a pulsing cursor that never
/// settles, so a broken read would hang the test rather than fail it.
Future<void> _answer(
  WidgetTester tester,
  _FakeChannel channel,
  Map<String, dynamic> body,
) async {
  channel.emit({
    'type': 'session-bus:directory:result',
    'requestId': channel.directoryRequestId,
    ...body,
  });
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Finder _rowFinder(String sessionId) =>
    find.byKey(Key('session-directory-row-$sessionId'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the read names the session the kebab was opened on', (
    tester,
  ) async {
    final channel = await _pump(tester);
    final request = channel.sent.single;
    expect(request['type'], 'session-bus:directory');
    expect(request['sessionId'], _sessionId);

    // Answered before the test ends: the read arms a timeout, and a test that
    // walks away from one leaves a pending timer rather than a clean pass.
    await _answer(tester, channel, {
      'sessions': const <Map<String, dynamic>>[],
      'truncated': 0,
      'machineId': null,
    });
    expect(find.text('No other sessions on this repository'), findsOneWidget);
  });

  testWidgets('this machine is grouped first, whatever order it arrived in', (
    tester,
  ) async {
    final channel = await _pump(tester);
    // Remote rows FIRST on the wire: the bridge sorts by branch, activity and
    // recency across every machine at once, so a peer legitimately outranks
    // this machine's own sessions and the grouping is the panel's own work.
    await _answer(tester, channel, {
      'sessions': [
        _row(
          sessionId: 's-peer',
          title: 'Chase the 401',
          machineId: 'm-peer',
          machineLabel: 'build-box',
          branch: 'fix/auth',
        ),
        _row(sessionId: 's-local', title: 'Trace the leak', machineId: 'm-me'),
      ],
      'truncated': 0,
      'machineId': 'm-me',
    });

    expect(find.text('THIS MACHINE'), findsOneWidget);
    expect(find.text('BUILD-BOX'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('THIS MACHINE')).dy,
      lessThan(tester.getTopLeft(find.text('BUILD-BOX')).dy),
    );
    expect(
      tester.getTopLeft(_rowFinder('s-local')).dy,
      lessThan(tester.getTopLeft(_rowFinder('s-peer')).dy),
    );
    expect(find.text('Trace the leak'), findsOneWidget);
    expect(find.text('fix/auth'), findsOneWidget);
  });

  testWidgets('a local row with no machine id is still this machine', (
    tester,
  ) async {
    final channel = await _pump(tester);
    // Local mode: no frame can leave the machine, so no row carries an id and
    // the answer names none either. Testing the row for null instead of
    // comparing it to the answer would file every session under "elsewhere".
    await _answer(tester, channel, {
      'sessions': [_row(sessionId: 's-local', title: 'Trace the leak')],
      'truncated': 0,
      'machineId': null,
    });

    expect(find.text('THIS MACHINE'), findsOneWidget);
    expect(_rowFinder('s-local'), findsOneWidget);
  });

  testWidgets('a receive-only session is listed and says so', (tester) async {
    final channel = await _pump(tester);
    await _answer(tester, channel, {
      'sessions': [
        _row(sessionId: 's-local', title: 'Trace the leak', canReply: true),
        _row(sessionId: 's-mute', title: 'Cursor Agent', canReply: false),
      ],
      'truncated': 0,
      'machineId': null,
    });

    // Listed, not hidden: an agent that can be told something is worth showing.
    expect(_rowFinder('s-mute'), findsOneWidget);
    expect(
      find.descendant(of: _rowFinder('s-mute'), matching: find.byType(AbChip)),
      findsOneWidget,
    );
    expect(find.text('RECEIVE-ONLY'), findsOneWidget);
    // The ordinary case carries no chip — a peer that can answer is what a
    // directory row already means.
    expect(
      find.descendant(of: _rowFinder('s-local'), matching: find.byType(AbChip)),
      findsNothing,
    );
  });

  testWidgets('a remote row is rendered by the canReply it arrived with', (
    tester,
  ) async {
    final channel = await _pump(tester);
    // Two rows off the SAME peer machine, differing only in the flag. Nothing
    // in the panel can tell them apart except the field itself, which is the
    // point: whether an agent can reply is decided by the bridge running it,
    // and this machine's own registry has no say in it.
    await _answer(tester, channel, {
      'sessions': [
        _row(
          sessionId: 's-peer-talks',
          title: 'Chase the 401',
          machineId: 'm-peer',
          machineLabel: 'build-box',
          canReply: true,
        ),
        _row(
          sessionId: 's-peer-mute',
          title: 'Rebuild the index',
          machineId: 'm-peer',
          machineLabel: 'build-box',
          canReply: false,
        ),
      ],
      'truncated': 0,
      'machineId': 'm-me',
    });

    expect(
      find.descendant(
        of: _rowFinder('s-peer-talks'),
        matching: find.byType(AbChip),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: _rowFinder('s-peer-mute'),
        matching: find.byType(AbChip),
      ),
      findsOneWidget,
    );
  });

  testWidgets('what the read could not see is stated, not implied', (
    tester,
  ) async {
    final channel = await _pump(tester);
    await _answer(tester, channel, {
      'sessions': [_row(sessionId: 's-local', title: 'Trace the leak')],
      'truncated': 2,
      'reach': {'scope': 'machine', 'why': 'remote-access-off'},
      'machineId': null,
    });

    expect(
      find.textContaining('Only this machine: remote access is off here.'),
      findsOneWidget,
    );
    expect(find.textContaining('2 more sessions did not fit.'), findsOneWidget);
  });

  testWidgets(
    'a machine both stale and refused is counted once, not twice',
    (tester) async {
      final channel = await _pump(tester);
      await _answer(tester, channel, {
        'sessions': [_row(sessionId: 's-local', title: 'Trace the leak')],
        'truncated': 0,
        'reach': {
          'scope': 'account',
          'notConnected': 0,
          'staleMachines': 1,
          'machines': [
            {'machineId': 'm-peer', 'status': 'refused', 'ageMs': 999999},
          ],
        },
        'machineId': null,
      });

      expect(find.textContaining('1 machine could not be read.'), findsOneWidget);
      expect(find.textContaining('2 machines'), findsNothing);
    },
  );

  testWidgets('a refusal is rendered in the words it was authored in', (
    tester,
  ) async {
    final channel = await _pump(tester);
    await _answer(tester, channel, {
      'error': 'This project has no git remote, so nothing can be addressed.',
      'code': 'NOT_ADDRESSABLE',
    });

    // Never collapsed into an empty list: "nobody is here" and "this project
    // cannot be addressed" are different facts and only one of them is fixable.
    expect(
      find.text('This project has no git remote, so nothing can be addressed.'),
      findsOneWidget,
    );
    expect(find.text('No other sessions on this repository'), findsNothing);
  });
}
