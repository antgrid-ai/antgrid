// The agent panel's header strip on Carbon. It matches the workspace tab strip
// across the resizable divider (same height, `background` fill, `borderSubtle00`
// rule), is one Carbon surface at both breakpoints, and on a phone is tall
// enough for the touch target of the kebab it carries. Assertions read what is
// laid out and painted, not constructor arguments.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/checkout_readiness.dart';
import 'package:antgrid/providers/checkout_readiness.dart';
import 'package:antgrid/providers/focused_tools.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/session_breadcrumb.dart';
import 'package:antgrid/widgets/workspace_readiness_chip.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

SessionEntry _session({String approval = 'default', String? tool}) =>
    SessionEntry(
      id: 'session-1',
      name: 'Session 1',
      createdAt: 0,
      lastUsedAt: 0,
      archived: false,
      running: true,
      mode: 'terminal',
      approvalPolicy: approval,
      tool: tool,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  /// [child] mounted under the overrides every case here shares. Platform and
  /// size are set by the caller; the platform is reset in its `finally`, never
  /// in a tear-down, which runs after the framework's own check.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required Size size,
    SessionEntry? session,
    CheckoutReadiness? readiness,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          visibleWorkspaceViewsProvider.overrideWithBuild(
            (_, _) => WorkspaceView.values,
          ),
          focusedMachineToolsProvider.overrideWith(
            (ref) async => const FocusedTools(),
          ),
          if (session != null) ...[
            activeSessionProvider.overrideWithValue(session),
            activeSessionIdProvider.overrideWith(
              () => ValueController(session.id),
            ),
          ],
          if (readiness != null)
            checkoutReadinessProvider.overrideWithValue(readiness),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder strip() => find.byKey(agentStripKey);

  group('desktop', () {
    testWidgets('has the height of the workspace tab strip and meets it at the '
        'bottom', (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        await pump(
          tester,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: AgentBar()),
              Expanded(
                child: WorkspaceTabBar(
                  selected: WorkspaceView.files,
                  onSelected: (_) {},
                ),
              ),
            ],
          ),
          size: const Size(1000, 800),
        );

        final bar = tester.getRect(strip());
        final tabs = tester.getRect(find.byType(WorkspaceTabBar));
        expect(bar.height, workspaceStripHeight);
        expect(bar.height, tabs.height);
        expect(bar.bottom, tabs.bottom);
        expect(bar.top, tabs.top);
        // The rule is the strip's own bottom border, drawn inside that height:
        // the row above it is one hairline shorter.
        final row = tester.getRect(
          find.descendant(of: strip(), matching: find.byType(SizedBox)).first,
        );
        expect(row.height, workspaceStripHeight - CarbonBorders.hairline);
        expect(row.top, bar.top);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('is filled with the background layer over a subtle bottom rule',
        (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        await pump(tester, const AgentBar(), size: const Size(1000, 800));

        final colors = CarbonTheme.of(tester.element(strip())).colors;
        final decoration =
            tester.widget<Container>(strip()).decoration! as BoxDecoration;
        expect(decoration.color, colors.background);
        final border = decoration.border! as Border;
        expect(border.bottom.color, colors.borderSubtle00);
        expect(border.bottom.width, CarbonBorders.hairline);
        expect(border.top, BorderSide.none);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('builds no Ab widget under its scope', (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        await pump(
          tester,
          const AgentPanel(),
          size: const Size(1000, 800),
          session: _session(approval: 'bypass'),
          readiness: CheckoutReadiness.stalled,
        );

        final scope = find.ancestor(
          of: strip(),
          matching: find.byType(AbCarbonScope),
        );
        expect(scope, findsOneWidget);
        expect(
          abWidgetsInScope(
            tester,
            scope: scope,
            allow: const {'AbAgentMark', 'AbCarbonScope'},
          ),
          isEmpty,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('phone', () {
    testWidgets('is a touch target tall and the kebab keeps its full size', (
      tester,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pump(
          tester,
          const AgentPanel(),
          size: const Size(400, 800),
          session: _session(),
        );

        expect(tester.getSize(strip()).height, greaterThanOrEqualTo(44));
        expect(tester.getSize(strip()).height, workspaceStripHeight);
        final trigger = find
            .descendant(
              of: find.byType(CarbonOverflowMenu),
              matching: find.byType(CarbonButton),
            )
            .first;
        expect(tester.getSize(trigger), const Size(44, 44));
        final projects = find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel == 'Projects',
        );
        expect(tester.getSize(projects), const Size(44, 44));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('builds no Ab widget under its scope', (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pump(
          tester,
          const AgentPanel(),
          size: const Size(400, 800),
          session: _session(approval: 'bypass'),
          readiness: CheckoutReadiness.stalled,
        );

        final scope = find.ancestor(
          of: strip(),
          matching: find.byType(AbCarbonScope),
        );
        expect(scope, findsOneWidget);
        expect(
          abWidgetsInScope(
            tester,
            scope: scope,
            allow: const {'AbAgentMark', 'AbCarbonScope'},
          ),
          isEmpty,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // The narrowest phone, with the two longest things the row can carry: the
    // YOLO badge and a stalled checkout's label.
    testWidgets('320 wide with YOLO and a stalled checkout does not overflow', (
      tester,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pump(
          tester,
          const AgentPanel(),
          size: const Size(320, 800),
          session: _session(approval: 'bypass', tool: 'claude'),
          readiness: CheckoutReadiness.stalled,
        );

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('session-yolo-badge')), findsOneWidget);
        expect(
          tester
              .widgetList<CarbonTag>(find.byType(CarbonTag))
              .any((tag) => tag.label == "Couldn't reach agent"),
          isTrue,
        );
        // Both share what is left, the title still naming the session.
        expect(
          tester.getSize(find.byType(TitleBarBreadcrumb)).width,
          greaterThan(0),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // What the chip reports is why the user is looking, so where the row has
    // room it keeps its whole label rather than a share-sized stub.
    testWidgets('a stalled checkout keeps its whole label where the row has room', (
      tester,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        // Real Plex: the test font is about twice as wide, which would push
        // the label past the tag's own 208px cap and truncate it regardless.
        await tester.runAsync(() async {
          final loader = FontLoader(
            'packages/${CarbonTypography.package}/${CarbonTypography.sansFamily}',
          );
          for (final f in ['IBMPlexSans-Regular.ttf', 'IBMPlexSans-SemiBold.ttf']) {
            loader.addFont(
              rootBundle.load(
                'packages/${CarbonTypography.package}/assets/fonts/$f',
              ),
            );
          }
          await loader.load();
        });
        await pump(
          tester,
          const AgentPanel(),
          size: const Size(590, 800),
          session: _session(tool: 'claude'),
          readiness: CheckoutReadiness.stalled,
        );

        final label = find.descendant(
          of: find.byType(WorkspaceReadinessChip),
          matching: find.text("Couldn't reach agent"),
        );
        expect(label, findsOneWidget);
        expect(
          tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // The badge brings its own leading gap; a bar-level spacer on top of it
    // doubled the distance from the mark.
    testWidgets('the YOLO badge sits one gap from the agent mark', (
      tester,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await pump(
          tester,
          const AgentPanel(),
          size: const Size(400, 800),
          session: _session(approval: 'bypass', tool: 'claude'),
        );

        final mark = tester.getRect(find.byKey(const Key('session-agent-mark')));
        final badge = tester.getRect(find.byKey(const Key('session-yolo-badge')));
        expect(badge.left - mark.right, CarbonSpacing.spacing03);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
