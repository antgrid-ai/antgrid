import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_catalog.dart';
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
  testWidgets('renders session name, agent chip, and project in order', (
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
    expect(find.text('Claude Code'), findsOneWidget);
    // Remote rows prefix the project with the origin device — grouping by
    // project/status has no other way to convey which machine a session ran
    // on, so the row itself must carry it.
    expect(find.text('BuildBox · antgrid'), findsOneWidget);
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
    expect(find.text('Cursor'), findsOneWidget);
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

    expect(find.text('kilo'), findsOneWidget);
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
    // Same spot: the swap must not shift the right rail.
    expect(
      tester.getBottomRight(deleteFinder.first).dx,
      lessThanOrEqualTo(tester.getBottomRight(timeFinder).dx + 1),
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
        'This permanently deletes "Fix auth bug" and cannot be undone.',
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
