// The Recents row has to show the same pending state as the drawer — and for a
// REMOTE row it is the only surface that can, because control-plane session
// lists are polled peeks that never carry the bridge's `deleting` flag.
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/session_delete_pending.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/recent_sessions/recent_session_row_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEntry _session({bool deleting = false}) => SessionEntry(
  id: 's1',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  tool: 'claude-code',
  deleting: deleting,
);

RecentSessionRow _row({bool deleting = false}) => RecentSessionRow(
  session: _session(deleting: deleting),
  origin: const RecentOrigin(
    isLocal: false,
    registrationId: 'uuidA.projRemote',
    projectId: 'projRemote',
    machineUuid: 'uuidA',
    projectName: 'antgrid',
    deviceName: 'BuildBox',
  ),
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  RecentSessionRow row, {
  required double width,
  VoidCallback? onOpened,
}) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return SizedBox(
                width: width,
                child: RecentSessionRowWidget(row: row, onOpened: onOpened),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Hover highlights are suppressed outright under the touch highlight mode the
/// test binding's default platform selects, so a hover assertion has to name a
/// pointer platform to be about the row at all.
void _asMouseDesktop() {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

/// Moves a synthetic mouse over the row. A deleting row's
/// [FocusableActionDetector] is disabled, so its hover callback never fires —
/// which is exactly the mechanism that keeps the delete affordance away.
Future<void> _hoverRow(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byType(RecentSessionRowWidget)));
  // Not pumpAndSettle: the pending row pulses forever, by design. Two frames:
  // the mouse tracker resolves the enter after the frame it arrived in.
  await tester.pump();
  await tester.pump();
}

/// Reads the fade through the plain [Opacity] that `AbCrossFade` drives, not
/// through `AbCrossFade` itself: its `visible` is the requested end state,
/// while this is what the row is actually painting on the frame under test.
double _deleteOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.byTooltip('Delete session'),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  testWidgets('the wire flag marks the desktop row and drops its delete', (
    tester,
  ) async {
    _asMouseDesktop();
    var opened = false;
    await _pump(
      tester,
      _row(deleting: true),
      width: 900,
      onOpened: () => opened = true,
    );

    expect(find.text('Fix auth bug'), findsOneWidget);
    expect(find.text('DELETING'), findsOneWidget);
    // The leading glyph takes the pulse: identity and work status both describe
    // an agent that is about to stop existing.
    expect(find.byType(AbLoadingDot), findsOneWidget);
    expect(find.byTooltip('Claude Code'), findsNothing);
    // The desktop rail cross-fades its delete in over the time label; hovering
    // a deleting row must leave the time where it is.
    await _hoverRow(tester);
    expect(_deleteOpacity(tester), 0);

    await tester.tap(find.byType(RecentSessionRowWidget), warnIfMissed: false);
    await tester.pump();
    expect(opened, isFalse);

    // Not focusable either: Tab must not reach a row that cannot be opened.
    final detector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byType(RecentSessionRowWidget),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    expect(detector.enabled, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the mobile layout drops its always-visible trash button', (
    tester,
  ) async {
    await _pump(tester, _row(deleting: true), width: 380);

    expect(find.text('DELETING'), findsOneWidget);
    expect(find.byTooltip('Delete session'), findsNothing);
  });

  testWidgets('an undeleted row keeps its mark and its delete', (tester) async {
    await _pump(tester, _row(), width: 380);

    expect(find.text('DELETING'), findsNothing);
    expect(find.byType(AbLoadingDot), findsNothing);
    expect(find.byTooltip('Delete session'), findsOneWidget);
  });

  // The control: the same hover on a row that is NOT deleting does reveal it,
  // so the assertion above is about the flag and not about the gesture.
  testWidgets('hovering an ordinary desktop row still reveals its delete', (
    tester,
  ) async {
    _asMouseDesktop();
    await _pump(tester, _row(), width: 900);
    await _hoverRow(tester);
    expect(_deleteOpacity(tester), 1);
    debugDefaultTargetPlatformOverride = null;
  });

  // The control-plane path the bridge's flag never reaches: the app's own mark
  // is the only pending signal a remote Recents row gets.
  testWidgets('an armed local mark renders the same as the wire flag', (
    tester,
  ) async {
    final container = await _pump(tester, _row(), width: 380);
    expect(find.text('DELETING'), findsNothing);

    container
        .read(sessionDeleteRequestsProvider.notifier)
        .arm(sessionDeleteKey('uuidA.projRemote', 's1'));
    await tester.pump();

    expect(find.text('DELETING'), findsOneWidget);
    expect(find.byType(AbLoadingDot), findsOneWidget);
    expect(find.byTooltip('Delete session'), findsNothing);
  });
}
