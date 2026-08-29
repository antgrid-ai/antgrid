import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/session_shared_workspace_badge.dart';

SessionEntry _session({bool shared = false, int members = 1}) => SessionEntry(
  id: 's1',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  sharedWorkspace: shared,
  workspaceMemberCount: members,
);

Widget _wrap(SessionEntry session) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
  ),
  home: Scaffold(
    body: Center(child: SessionSharedWorkspaceBadge(session: session)),
  ),
);

Finder _badgeGlyph() => find.byWidgetPredicate(
  (w) => w is AbIcon && w.icon == AbIcons.sharedWorkspace,
);

void main() {
  testWidgets('a session that owns its workspace wears no badge', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session()));
    expect(_badgeGlyph(), findsNothing);
  });

  testWidgets('a shared workspace is badged, and the count is in the tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session(shared: true, members: 3)));
    expect(_badgeGlyph(), findsOneWidget);
    // The count belongs to the tooltip, never to the row: a number that moves
    // as sessions come and go is motion beside a name the user is scanning.
    expect(find.textContaining('3'), findsNothing);
    expect(
      find.byTooltip(
        'Shared workspace — 2 other sessions work in this directory. Every one '
        'of them edits the same files and commits to the same branch, at the '
        'same time.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('one other session is counted in the singular', (tester) async {
    await tester.pumpWidget(_wrap(_session(shared: true, members: 2)));
    expect(
      find.byTooltip(
        'Shared workspace — 1 other session works in this directory. Every one '
        'of them edits the same files and commits to the same branch, at the '
        'same time.',
      ),
      findsOneWidget,
    );
  });

  // An older bridge can set the flag and omit the count, which the model
  // defaults to 1. The badge still has something true to say, and must not
  // offer to count zero other sessions.
  testWidgets('a shared session with no count still explains itself', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session(shared: true)));
    expect(_badgeGlyph(), findsOneWidget);
    expect(
      find.byTooltip(
        'Shared workspace — other sessions work in this directory, editing the '
        'same files and committing to the same branch.',
      ),
      findsOneWidget,
    );
  });
}
