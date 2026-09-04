import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/session_member_badge.dart';

SessionEntry _session({SessionMemberOf? memberOf}) => SessionEntry(
  id: 's1',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  memberOf: memberOf,
);

SessionMemberOf _lead({String? machineLabel, String state = 'active'}) =>
    SessionMemberOf(
      ref: SessionMemberRef(
        machineId: 'device-uuid-1',
        projectId: 'proj-1',
        sessionId: 'sess-1',
        machineLabel: machineLabel,
      ),
      joinedAt: 10,
      state: state,
    );

Widget _wrap(SessionEntry session) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
  ),
  home: Scaffold(body: Center(child: SessionMemberBadge(session: session))),
);

Finder _badgeGlyph() => find.byWidgetPredicate(
  (w) => w is AbIcon && w.icon == AbIcons.sessionMemberOf,
);

void main() {
  testWidgets('a session that leads itself wears no badge', (tester) async {
    await tester.pumpWidget(_wrap(_session()));
    expect(_badgeGlyph(), findsNothing);
  });

  testWidgets('a member session names its lead machine in the tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session(memberOf: _lead(machineLabel: 'Studio'))));
    expect(_badgeGlyph(), findsOneWidget);
    expect(
      find.byTooltip('Member session — part of a session led on Studio.'),
      findsOneWidget,
    );
  });

  // A carrier that recorded the membership before it could resolve a name
  // leaves the label off. The id is a worse name but a true one, and saying
  // nothing about the machine would be the badge withholding what it knows.
  testWidgets('an unlabelled lead falls back to the machine id', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session(memberOf: _lead())));
    expect(
      find.byTooltip(
        'Member session — part of a session led on device-uuid-1.',
      ),
      findsOneWidget,
    );
  });

  // An unreachable lead changes what the badge says, never what exists: the
  // session is intact and nothing is removed on the word of an absence.
  testWidgets('an orphaned member still shows, and says the lead is silent', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _session(memberOf: _lead(machineLabel: 'Studio', state: 'orphaned')),
      ),
    );
    expect(_badgeGlyph(), findsOneWidget);
    expect(
      find.byTooltip(
        'Member session — its lead on Studio has not answered. Nothing is '
        'removed while a lead is unreachable; this clears when it answers '
        'again.',
      ),
      findsOneWidget,
    );
  });
}
