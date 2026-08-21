import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/session_isolation_badge.dart';

SessionEntry _session({
  String checkoutKind = 'main',
  String checkoutState = 'ready',
}) => SessionEntry(
  id: 's1',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  checkoutKind: checkoutKind,
  checkoutState: checkoutState,
);

Widget _wrap(SessionEntry session) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
  ),
  home: Scaffold(
    body: Center(child: SessionIsolationBadge(session: session)),
  ),
);

Finder _badgeGlyph() =>
    find.byWidgetPredicate((w) => w is AbIcon && w.icon == AbIcons.isolated);

void main() {
  testWidgets('a session on the shared tree wears no badge', (tester) async {
    await tester.pumpWidget(_wrap(_session()));
    expect(_badgeGlyph(), findsNothing);
  });

  testWidgets('a managed worktree is badged and named without its mechanism', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session(checkoutKind: 'managed-worktree')));
    expect(_badgeGlyph(), findsOneWidget);
    // The badge stands for isolation, not for the backend delivering it, so its
    // copy must survive a second backend landing beside worktrees.
    expect(find.textContaining('worktree'), findsNothing);
    expect(
      find.byTooltip(
        'Isolated session — its own workspace, separate from your main tree.',
      ),
      findsOneWidget,
    );
  });

  // The forward pin: isolation is derived by exclusion from `main`, so a kind
  // this build has never been taught still wears the marker. Matching kinds by
  // name instead would leave a future one looking like a shared session.
  testWidgets('a checkout kind this build does not know is still isolated', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_session(checkoutKind: 'external-worktree')));
    expect(_badgeGlyph(), findsOneWidget);

    await tester.pumpWidget(_wrap(_session(checkoutKind: 'dev-container')));
    expect(_badgeGlyph(), findsOneWidget);
  });

  testWidgets('an unrecognised checkout state degrades to the weakest claim', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _session(checkoutKind: 'managed-worktree', checkoutState: 'pulling'),
      ),
    );
    expect(_badgeGlyph(), findsOneWidget);
    // Neither healthy nor broken — the bridge owns this vocabulary and the row
    // must not guess which side of it an unknown value falls on.
    expect(find.byTooltip('Isolated session.'), findsOneWidget);
  });

  testWidgets('a checkout the bridge cannot reach says so', (tester) async {
    for (final state in ['missing', 'failed']) {
      await tester.pumpWidget(
        _wrap(_session(checkoutKind: 'managed-worktree', checkoutState: state)),
      );
      expect(
        find.byTooltip('This isolated session\'s workspace is unavailable.'),
        findsOneWidget,
        reason: 'checkoutState "$state" must read as unavailable',
      );
    }
  });

  // The badge is a bare glyph, so the tooltip is its ONLY explanation — and on
  // touch a long-press (Material's default trigger) is not discoverable enough
  // to be that. Tap must open it.
  testWidgets('a tap on the glyph opens the tooltip', (tester) async {
    await tester.pumpWidget(_wrap(_session(checkoutKind: 'managed-worktree')));
    await tester.tap(_badgeGlyph());
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Isolated session — its own workspace, separate from your main tree.',
      ),
      findsOneWidget,
    );
  });
}
