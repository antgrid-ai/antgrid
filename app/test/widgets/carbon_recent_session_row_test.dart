import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_agent_mark.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/session_delete_pending.dart';
import 'package:antgrid/widgets/recent_sessions/carbon_recent_session_row.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_summary.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

SessionEntry _session({
  bool deleting = false,
  String? tool = 'claude-code',
  String? command,
  String approvalPolicy = 'default',
  String checkoutKind = 'main',
}) => SessionEntry(
  id: 's1',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  tool: tool,
  command: command,
  deleting: deleting,
  approvalPolicy: approvalPolicy,
  checkoutKind: checkoutKind,
);

RecentSessionRow _row(SessionEntry session) => RecentSessionRow(
  session: session,
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
  RecentGroupBy? groupedBy,
}) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildAbTheme(),
        home: AbCarbonScope(
          child: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: CarbonRecentSessionRow(
                      row: row,
                      groupedBy: groupedBy,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// [testWidgets] that clears the platform override inside the body: the
/// binding checks foundation debug variables before any tearDown runs.
void _testRow(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Hover is only tracked on a pointer platform.
void _asMouseDesktop() {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
}

Future<void> _hover(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byType(CarbonRecentSessionRow)));
  await tester.pump();
  await tester.pump();
}

/// Whether the contained row is currently revealing its actions cell. The
/// nearest Visibility is the row's own delete guard; the next one out is the
/// cell's hover reveal.
bool _actionsRevealed(WidgetTester tester) => tester
    .widget<Visibility>(
      find
          .ancestor(
            of: find.byType(CarbonButton),
            matching: find.byType(Visibility),
          )
          .at(1),
    )
    .visible;

void main() {
  _testRow('desktop rail has no Ab widget and no separate status glyph', (
    tester,
  ) async {
    _asMouseDesktop();
    await _pump(tester, _row(_session()), width: 900);
    expect(find.text('Fix auth bug'), findsOneWidget);
    expect(find.text('BuildBox · antgrid'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
    expect(find.byType(CarbonIconIndicator), findsNothing);
  });

  _testRow('the rail falls back to stacked on the OUTER width', (
    tester,
  ) async {
    _asMouseDesktop();
    await _pump(tester, _row(_session()), width: 900);
    // Centres, not tops: the name and the project are set in different type.
    expect(
      tester.getCenter(find.text('BuildBox · antgrid')).dy,
      moreOrLessEquals(
        tester.getCenter(find.text('Fix auth bug')).dy,
        epsilon: 1,
      ),
    );

    // Past the breakpoint on the outer width but not once the row's padding
    // and leading slot are taken off: only an outer measure keeps the rail.
    await _pump(tester, _row(_session()), width: 600);
    expect(
      tester.getCenter(find.text('BuildBox · antgrid')).dy,
      moreOrLessEquals(
        tester.getCenter(find.text('Fix auth bug')).dy,
        epsilon: 1,
      ),
    );

    await _pump(tester, _row(_session()), width: 540);
    expect(
      tester.getTopLeft(find.text('BuildBox · antgrid')).dy,
      greaterThan(tester.getTopLeft(find.text('Fix auth bug')).dy),
    );
  });

  _testRow('group header drops what it already names', (tester) async {
    await _pump(
      tester,
      _row(_session()),
      width: 900,
      groupedBy: RecentGroupBy.machine,
    );
    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('BuildBox · antgrid'), findsNothing);
  });

  _testRow('accessible name carries the status word and the badges', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final container = await _pump(
      tester,
      _row(
        _session(approvalPolicy: 'bypass', checkoutKind: 'managed-worktree'),
      ),
      width: 900,
    );
    container
        .read(remoteSessionStatusProvider.notifier)
        .setLocalSessionStatuses({
          'uuidA.projRemote': {'s1': AgentWorkStatus.attention},
        });
    await tester.pump();
    expect(
      find.bySemanticsLabel(
        RegExp(
          r'^Fix auth bug, Needs you, [^,]+, BuildBox · antgrid, .*, bypasses approvals, isolated$',
        ),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  _testRow('delete keeps its width, is revealed on hover, then confirms', (
    tester,
  ) async {
    _asMouseDesktop();
    await _pump(tester, _row(_session()), width: 900);
    final before = tester.getTopLeft(find.byType(CarbonButton));
    expect(_actionsRevealed(tester), isFalse);

    await _hover(tester);
    expect(_actionsRevealed(tester), isTrue);
    expect(tester.getTopLeft(find.byType(CarbonButton)), before);

    await tester.tap(find.byType(CarbonButton));
    await tester.pumpAndSettle();
    expect(find.text('Delete session?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  _testRow('a deleting row shows the spinner and offers no delete', (
    tester,
  ) async {
    _asMouseDesktop();
    await _pump(tester, _row(_session(deleting: true)), width: 900);
    expect(find.text('Deleting'), findsOneWidget);
    expect(find.byType(CarbonSpinner), findsOneWidget);
    await _hover(tester);
    final guard = tester.widget<Visibility>(
      find
          .ancestor(
            of: find.byType(CarbonButton),
            matching: find.byType(Visibility),
          )
          .first,
    );
    expect(guard.visible, isFalse);
  });

  _testRow('an armed local mark renders the same as the wire flag', (
    tester,
  ) async {
    final container = await _pump(tester, _row(_session()), width: 380);
    expect(find.text('Deleting'), findsNothing);
    container
        .read(sessionDeleteRequestsProvider.notifier)
        .arm(sessionDeleteKey('uuidA.projRemote', 's1'));
    await tester.pump();
    expect(find.text('Deleting'), findsOneWidget);
    expect(find.byType(CarbonSpinner), findsOneWidget);
  });

  _testRow('a custom command keeps its text and has no agent mark', (
    tester,
  ) async {
    await _pump(
      tester,
      _row(_session(tool: null, command: 'npm run dev')),
      width: 900,
    );
    expect(find.text('npm run dev'), findsOneWidget);
    expect(find.byType(AbAgentMark), findsNothing);
  });

  _testRow('touch always shows a 44pt delete target', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pump(tester, _row(_session()), width: 380);
    expect(_actionsRevealed(tester), isTrue);
    final size = tester.getSize(find.byType(CarbonButton));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });
}
