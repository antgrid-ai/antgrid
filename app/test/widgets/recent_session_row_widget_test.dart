import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_agent_mark.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/widgets/agent_work_status_dot.dart';
import 'package:antgrid/widgets/recent_sessions/recent_session_row_widget.dart';

/// A catalog notifier seeded with a fixed map, bypassing the disk hydration —
/// stands in for "a bridge has already described these agents".
class _SeededCatalog extends AgentCatalogNotifier {
  _SeededCatalog(this.seed);

  final Map<String, AgentDescriptor> seed;

  @override
  Map<String, AgentDescriptor> build() => seed;
}

AgentDescriptor _descriptor(String tool, String label) => AgentDescriptor(
  tool: tool,
  label: label,
  chatCapable: false,
  judgeCapable: false,
  handlerTerminal: false,
  handlerChat: false,
);

const _catalogSeed = <String, String>{
  'claude-code': 'Claude Code',
  'cursor-agent': 'Cursor',
};

Widget _wrap(Widget child, {Map<String, String> catalog = _catalogSeed}) {
  return ProviderScope(
    overrides: [
      agentCatalogProvider.overrideWith(
        () => _SeededCatalog({
          for (final e in catalog.entries) e.key: _descriptor(e.key, e.value),
        }),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('renders session name, agent mark, and project in order', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's1',
        name: 'Fix auth bug',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
        tool: 'claude-code',
      ),
      origin: const RecentOrigin(
        isLocal: false,
        registrationId: 'uuidA.projRemote',
        projectId: 'projRemote',
        machineUuid: 'uuidA',
        projectName: 'antgrid',
        deviceName: 'BuildBox',
      ),
    );

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    expect(find.text('Fix auth bug'), findsOneWidget);
    // The agent is a mark, not its name — the name survives as the tooltip.
    expect(find.text('Claude Code'), findsNothing);
    expect(find.byTooltip('Claude Code'), findsOneWidget);
    // Remote rows prefix the project with the origin device — grouping by
    // project/status has no other way to convey which machine a session ran
    // on, so the row itself must carry it.
    final projectFinder = find.text('BuildBox · antgrid');
    expect(projectFinder, findsOneWidget);

    // Order, left to right: agent mark · name · project · time. The mark leads
    // the row (it carries the status badge); the rail is metadata only.
    double leftOf(Finder f) => tester.getTopLeft(f).dx;
    expect(
      leftOf(find.byTooltip('Claude Code')),
      lessThan(leftOf(find.text('Fix auth bug'))),
    );
    expect(leftOf(find.text('Fix auth bug')), lessThan(leftOf(projectFinder)));
    expect(leftOf(projectFinder), lessThan(leftOf(find.textContaining('ago'))));
    debugDefaultTargetPlatformOverride = null;
  });

  // Identity and status are one leading glyph: the status rides the mark's
  // corner rather than claiming a column of its own.
  testWidgets('status badges the agent mark rather than sitting apart', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's6',
        name: 'Badged session',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: true,
        tool: 'claude-code',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    final markRect = tester.getRect(find.byType(AbAgentMark));
    final badgeRect = tester.getRect(find.byType(AgentWorkStatusBadge));
    // Overlapping, at the mark's lower-right — not a separate column.
    expect(badgeRect.overlaps(markRect), isTrue);
    expect(badgeRect.center.dx, greaterThan(markRect.center.dx));
    expect(badgeRect.center.dy, greaterThan(markRect.center.dy));

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('custom launch command keeps its text, not a monogram', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's5',
        name: 'Custom runner',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
        command: 'npm run dev',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    expect(find.text('npm run dev'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  // A session with neither a tool nor a command can't be identified, and
  // sessionAgentDisplayLabel answers that with the DEFAULT agent's name. Printing
  // it would dress a guess as data — and put the same agent on screen two ways,
  // since a row that really is Claude Code draws a mark and no text.
  testWidgets('unidentified session names no agent at all', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's7',
        name: 'Anonymous session',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    expect(find.text('Anonymous session'), findsOneWidget);
    expect(find.text('Claude Code'), findsNothing);
    expect(find.byType(AbAgentMark), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('running session shows activity dot', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's2',
        name: 'Running session',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: true,
        tool: 'cursor-agent',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    expect(find.text('Running session'), findsOneWidget);
    expect(find.byTooltip('Cursor'), findsOneWidget);
    expect(find.text('my-project'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an agent no bridge has described wears its raw key', (
    tester,
  ) async {
    // The row belongs to another machine, which may be offline — the catalog is
    // all there is to name it, and a key it does not carry must read honestly
    // rather than fold onto whatever the app happens to ship knowing.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's3',
        name: 'Unknown agent',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
        tool: 'kilo',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(
      _wrap(RecentSessionRowWidget(row: row), catalog: const {}),
    );
    await tester.pump();

    expect(find.byTooltip('kilo'), findsOneWidget);
    expect(find.text(AbAgentMark.monogram('kilo')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('hover swaps time label for delete button in place', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's4',
        name: 'Hover target',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
        tool: 'claude-code',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    // At rest: time visible, delete transparent (it overlays the time in a
    // Stack rather than reserving a trailing slot).
    AnimatedOpacity opacityOf(Finder descendant) => tester.widget(
      find.ancestor(of: descendant, matching: find.byType(AnimatedOpacity)),
    );
    final timeFinder = find.textContaining('ago');
    final deleteFinder = find.byTooltip('Delete session');
    expect(opacityOf(timeFinder).opacity, 1);
    expect(opacityOf(deleteFinder).opacity, 0);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Hover target')));
    await tester.pumpAndSettle();

    expect(opacityOf(timeFinder).opacity, 0);
    expect(opacityOf(deleteFinder).opacity, 1);
    // Same spot: the swap must not shift the rail. The slot is left-aligned,
    // so it's the leading edge (not the trailing one) that must line up.
    expect(
      tester.getTopLeft(deleteFinder.first).dx,
      closeTo(tester.getTopLeft(timeFinder).dx, 1),
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on mobile project renders on a second line', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's3',
        name: 'Migration strategy',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: true,
        tool: 'claude-code',
      ),
      origin: const RecentOrigin(
        isLocal: false,
        registrationId: 'uuidA.antgrid',
        projectId: 'antgrid',
        machineUuid: 'uuidA',
        projectName: 'antgrid',
        deviceName: 'studio-workstation',
      ),
    );

    // Size the VIEW, not just the render surface: the row widget branches
    // mobile/desktop on MediaQuery.sizeOf, which reads the view's physical
    // size — setSurfaceSize alone leaves MediaQuery at 800×600 (desktop).
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    // Project (prefixed with the origin device) appears once, below the title
    // row (Fleet.astro mobile layout).
    final projectFinder = find.text('studio-workstation · antgrid');
    expect(projectFinder, findsOneWidget);
    final projectY = tester.getTopLeft(projectFinder).dy;
    final nameY = tester.getTopLeft(find.text('Migration strategy')).dy;
    expect(projectY, greaterThan(nameY));

    // The mark leads here too — between the name and the time it squeezes
    // both, which is the whole reason this layout has a leading column.
    expect(
      tester.getRect(find.byType(AbAgentMark)).left,
      lessThan(tester.getTopLeft(find.text('Migration strategy')).dx),
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile row exposes a trash button that opens a confirm dialog', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's4',
        name: 'Fix auth bug',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
        tool: 'claude-code',
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'localProj',
        projectId: 'localProj',
        machineUuid: null,
        projectName: 'my-project',
        deviceName: 'This device',
      ),
    );

    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(RecentSessionRowWidget(row: row)));
    await tester.pump();

    expect(find.byTooltip('Delete session'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete session'));
    await tester.pumpAndSettle();

    expect(find.text('Delete session?'), findsOneWidget);
    expect(
      find.text(
        'This permanently deletes "Fix auth bug". This cannot be undone.',
      ),
      findsOneWidget,
    );

    // Cancel — dialog dismisses without reaching the delete RPC path.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete session?'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });
}
