// The agent bar's identity cluster on Carbon: project / session path, branch
// tag, agent mark and the YOLO badge. Assertions read what is painted (colours
// resolved off the live Carbon theme, positions, tag labels), not constructor
// arguments.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_branch_pill.dart';
import 'package:antgrid/design/widgets/ab_breadcrumb.dart';
import 'package:antgrid/design/widgets/ab_tooltip.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/focused_tools.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/widgets/session_agent_mark.dart';
import 'package:antgrid/widgets/session_approval_badge.dart';
import 'package:antgrid/widgets/session_breadcrumb.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/clipboard.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';
import '../helpers/toast_host.dart';

const _projectId = 'identity-proj';

/// The breadcrumb reads the persistent stores (through the recents), which
/// throw unless overridden.
late TestStoreOverrides _stores;

SessionEntry _session({
  String approval = 'default',
  String? tool,
  String name = 'Fix the build',
}) =>
    SessionEntry(
      id: 'sess-1',
      name: name,
      createdAt: 0,
      lastUsedAt: 0,
      archived: false,
      running: false,
      approvalPolicy: approval,
      tool: tool,
    );

Widget _host(
  Widget child, {
  double width = 700,
  int ahead = 1,
  int behind = 2,
  SessionEntry? session,
  String project = 'antgrid',
  String branch = 'main',
}) => ProviderScope(
  overrides: [
    ..._stores.overrides,
    selectedRegistrationIdProvider.overrideWith((_) => _projectId),
    activeSessionProvider.overrideWithValue(session ?? _session()),
    focusedMachineToolsProvider.overrideWith(
      (ref) async => const FocusedTools(),
    ),
    terminalStateProvider.overrideWith(
      (ref) => Stream.value(
        TerminalState(
          agentInfo: AgentInfo(name: project),
          gitBranch: branch,
          gitAhead: ahead,
          gitBehind: behind,
        ),
      ),
    ),
  ],
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    builder: abToastHostBuilder,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

CarbonThemeData _theme(WidgetTester tester, Finder at) =>
    CarbonTheme.of(tester.element(at));

/// Every Ab widget under [root], found by scanning each [AbCarbonScope] on its
/// own: the guard stops at an allow-listed type, so allowing the scope while
/// scanning from outside it would skip everything inside.
List<String> _abInsideScopes(WidgetTester tester, Finder root) {
  final scopes = find.descendant(
    of: root,
    matching: find.byType(AbCarbonScope),
  );
  final count = scopes.evaluate().length;
  expect(count, greaterThan(0));
  return [
    for (var i = 0; i < count; i++)
      ...abWidgetsInScope(
        tester,
        scope: scopes.at(i),
        allow: const {'AbAgentMark', 'AbCarbonScope'},
      ),
  ];
}

void main() {
  setUp(() async {
    useInMemoryPrefs();
    _stores = await buildTestStoreOverrides();
  });
  tearDown(() => _stores.close());

  group('project / session path', () {
    testWidgets('paints the project secondary, the session primary, " / " '
        'between them, and no breadcrumb', (tester) async {
      await tester.pumpWidget(_host(const TitleBarBreadcrumb()));
      await _settle(tester);

      final project = find.byKey(const Key('breadcrumb-project'));
      final sep = find.byKey(const Key('breadcrumb-separator'));
      final session = find.byKey(const Key('breadcrumb-session'));
      final colors = _theme(tester, project).colors;

      expect(tester.widget<Text>(project).data, 'antgrid');
      expect(tester.widget<Text>(project).style!.color, colors.textSecondary);
      expect(tester.widget<Text>(sep).data, ' / ');
      expect(tester.widget<Text>(session).data, 'Fix the build');
      expect(tester.widget<Text>(session).style!.color, colors.textPrimary);
      expect(colors.textSecondary, isNot(colors.textPrimary));

      // Left to right: project, separator, session.
      expect(
        tester.getTopLeft(project).dx,
        lessThan(tester.getTopLeft(sep).dx),
      );
      expect(
        tester.getTopLeft(sep).dx,
        lessThan(tester.getTopLeft(session).dx),
      );

      // Neither segment navigates, so nothing may be styled as a link.
      expect(find.byType(CarbonBreadcrumb), findsNothing);
      expect(find.byType(AbBreadcrumb), findsNothing);
      for (final f in [project, session]) {
        expect(tester.widget<Text>(f).style!.decoration, isNot(TextDecoration.underline));
      }
    });

    testWidgets('tapping the session opens the Carbon rename dialog', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const TitleBarBreadcrumb()));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('breadcrumb-session')));
      await tester.pumpAndSettle();

      expect(find.byType(CarbonModal), findsOneWidget);
      expect(find.text('Rename session'), findsOneWidget);
      // The name is preselected in the field.
      expect(find.byType(EditableText), findsOneWidget);
    });

    testWidgets('tapping the project does nothing', (tester) async {
      await tester.pumpWidget(_host(const TitleBarBreadcrumb()));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('breadcrumb-project')));
      await tester.pumpAndSettle();

      expect(find.byType(CarbonModal), findsNothing);
    });

    testWidgets('collapses to the session name alone when narrow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const TitleBarBreadcrumb(showBranchPill: false), width: 200),
      );
      await _settle(tester);

      expect(find.byKey(const Key('breadcrumb-session')), findsOneWidget);
      expect(find.byKey(const Key('breadcrumb-project')), findsNothing);
      expect(find.byKey(const Key('breadcrumb-separator')), findsNothing);

      await tester.pumpWidget(
        _host(const TitleBarBreadcrumb(showBranchPill: false), width: 700),
      );
      await _settle(tester);

      expect(find.byKey(const Key('breadcrumb-project')), findsOneWidget);
      expect(find.byKey(const Key('breadcrumb-separator')), findsOneWidget);
    });

    testWidgets('showBranchPill false leaves the branch tag out', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const TitleBarBreadcrumb()));
      await _settle(tester);
      expect(find.byType(CarbonTag), findsOneWidget);

      await tester.pumpWidget(
        _host(const TitleBarBreadcrumb(showBranchPill: false)),
      );
      await _settle(tester);

      expect(find.byType(CarbonTag), findsNothing);
      expect(find.byType(AbBranchPill), findsNothing);
    });

    testWidgets('a long session name takes all the room a short project '
        'leaves, with no empty slack after it', (tester) async {
      await tester.pumpWidget(
        _host(
          const TitleBarBreadcrumb(showBranchPill: false),
          session: _session(name: 'A very long session name ' * 12),
        ),
      );
      await _settle(tester);

      expect(
        tester.getRect(find.byKey(const Key('breadcrumb-session'))).right,
        closeTo(tester.getRect(find.byType(TitleBarBreadcrumb)).right, 0.5),
      );
    });

    // A phone header read "demo-shop (sa… / Add checkout valid…": the project's
    // fixed cap took width the session needed. The session is what the user
    // acts on, so the project gives way first.
    testWidgets('on a narrow header the project truncates before the session', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const TitleBarBreadcrumb(showBranchPill: false),
          width: 300,
          project: 'demo-shop (sample)',
          session: _session(name: 'Fix checkout'),
        ),
      );
      await _settle(tester);

      RenderParagraph paragraph(String key) =>
          tester.renderObject<RenderParagraph>(find.byKey(Key(key)));
      expect(find.byKey(const Key('breadcrumb-project')), findsOneWidget);
      expect(paragraph('breadcrumb-session').didExceedMaxLines, isFalse);
      expect(paragraph('breadcrumb-project').didExceedMaxLines, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the session name is tappable a little above and below its '
        'text under touch density', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(_host(const TitleBarBreadcrumb()));
        await _settle(tester);

        final text = tester.getRect(
          find.byKey(const Key('breadcrumb-session')),
        );
        await tester.tapAt(Offset(text.left + 4, text.top - 8));
        await tester.pumpAndSettle();

        expect(find.byType(CarbonModal), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('mounts no Ab widget', (tester) async {
      await tester.pumpWidget(_host(const TitleBarBreadcrumb()));
      await _settle(tester);

      expect(_abInsideScopes(tester, find.byType(TitleBarBreadcrumb)), isEmpty);
    });
  });

  group('branch tag', () {
    String label(WidgetTester tester) =>
        tester.widget<CarbonTag>(find.byKey(const Key('session-branch-tag'))).label;

    testWidgets('folds behind then ahead into the label', (tester) async {
      await tester.pumpWidget(_host(const SessionBranchPill()));
      await _settle(tester);

      expect(label(tester), 'main ↓2 ↑1');
      expect(find.text('main ↓2 ↑1'), findsOneWidget);
      expect(find.byType(AbBranchPill), findsNothing);
    });

    testWidgets('shows an arrow only for a non-zero count', (tester) async {
      await tester.pumpWidget(
        _host(const SessionBranchPill(), ahead: 3, behind: 0),
      );
      await _settle(tester);
      expect(find.text('main ↑3'), findsOneWidget);
    });

    testWidgets('behind alone shows only the down arrow', (tester) async {
      await tester.pumpWidget(
        _host(const SessionBranchPill(), ahead: 0, behind: 4),
      );
      await _settle(tester);
      expect(find.text('main ↓4'), findsOneWidget);
    });

    testWidgets('a branch level with its upstream shows the name alone', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const SessionBranchPill(), ahead: 0, behind: 0),
      );
      await _settle(tester);

      expect(label(tester), 'main');
    });

    testWidgets('tapping copies the branch name and says so', (tester) async {
      final copied = captureClipboard(tester);
      await tester.pumpWidget(_host(const SessionBranchPill()));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('session-branch-tag')));
      await tester.pump();
      await tester.pump();

      expect(copied, ['main']);
      expect(find.text('Copied "main"'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    // A fixed 160 cap cut "feat/carbon-flutter" short with the rest of the
    // header empty beside it. The name stays under Carbon's own 208 tag cap,
    // which the test font (one em per glyph) reaches far sooner than Plex.
    testWidgets('beside a short title the tag shows its whole name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const TitleBarBreadcrumb(),
          width: 780,
          ahead: 0,
          behind: 0,
          branch: 'feat/carbon',
        ),
      );
      await _settle(tester);

      final text = find.descendant(
        of: find.byKey(const Key('session-branch-tag')),
        matching: find.text('feat/carbon'),
      );
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
      );
      expect(
        tester.getSize(find.byKey(const Key('session-branch-tag'))).width,
        greaterThan(160),
      );
    });

    // Where the row is tight the session keeps the room and the tag gives way,
    // but never below its floor.
    testWidgets('a long session name leaves the tag its floor', (tester) async {
      await tester.pumpWidget(
        _host(
          const TitleBarBreadcrumb(),
          width: 780,
          ahead: 0,
          behind: 0,
          branch: 'feat/a-very-long-branch-name-for-the-tag',
          session: _session(name: 'A very long session name ' * 12),
        ),
      );
      await _settle(tester);

      final tag = tester.getRect(find.byKey(const Key('session-branch-tag')));
      expect(tag.width, greaterThanOrEqualTo(150));
      expect(tag.right, lessThanOrEqualTo(780.5));
      expect(
        tester.getRect(find.byKey(const Key('breadcrumb-session'))).right,
        lessThanOrEqualTo(tag.left),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long name truncates inside maxWidth', (tester) async {
      await tester.pumpWidget(
        // Loose, so the cap is the only thing narrowing the tag.
        _host(
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: SessionBranchPill(maxWidth: 120),
          ),
          width: 600,
        ),
      );
      await _settle(tester);

      expect(
        tester.getSize(find.byKey(const Key('session-branch-tag'))).width,
        lessThanOrEqualTo(120),
      );
    });
  });

  group('approval badge', () {
    testWidgets('a bypass session shows the Carbon YOLO tag', (tester) async {
      await tester.pumpWidget(
        _host(
          const ActiveSessionApprovalBadge(),
          session: _session(approval: 'bypass'),
        ),
      );
      await _settle(tester);

      final tag = find.byKey(const Key('session-yolo-badge'));
      expect(tester.widget<CarbonTag>(tag).label, 'YOLO');
      expect(tester.widget<CarbonTag>(tag).color, CarbonTagColor.red);
    });

    testWidgets('only a bypass policy shows the tag', (tester) async {
      await tester.pumpWidget(_host(const ActiveSessionApprovalBadge()));
      await _settle(tester);
      expect(find.byType(CarbonTag), findsNothing);

      await tester.pumpWidget(
        _host(
          const ActiveSessionApprovalBadge(),
          session: _session(approval: 'bypass'),
        ),
      );
      await _settle(tester);
      expect(find.byType(CarbonTag), findsOneWidget);
    });
  });

  group('agent mark', () {
    testWidgets('is a Carbon tooltip over the brand mark with a Carbon dot', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SessionAgentMark(),
          session: _session(tool: 'zz-unknown-agent'),
        ),
      );
      await _settle(tester);

      final mark = find.byKey(const Key('session-agent-mark'));
      expect(mark, findsOneWidget);
      expect(
        find.ancestor(of: mark, matching: find.byType(CarbonTooltip)),
        findsOneWidget,
      );
      expect(find.byType(AbTooltip), findsNothing);
      expect(find.byType(CarbonWorkStatusDot), findsOneWidget);

      // The dot hangs off the mark's corner rather than sitting beside it.
      final dot = tester.getRect(find.byType(CarbonWorkStatusDot));
      final box = tester.getRect(mark);
      expect(dot.center.dx, greaterThan(box.center.dx));
      expect(dot.center.dy, greaterThan(box.center.dy));
      expect(dot.right, greaterThan(box.right - 1));
    });

    testWidgets('without a tool it falls back to the bare dot', (tester) async {
      await tester.pumpWidget(_host(const SessionAgentMark()));
      await _settle(tester);

      expect(find.byKey(const Key('session-agent-mark')), findsNothing);
      expect(find.byType(CarbonWorkStatusDot), findsOneWidget);
    });

    testWidgets('mounts no Ab widget but the brand mark', (tester) async {
      await tester.pumpWidget(
        _host(
          const SessionAgentMark(),
          session: _session(tool: 'zz-unknown-agent'),
        ),
      );
      await _settle(tester);

      expect(_abInsideScopes(tester, find.byType(SessionAgentMark)), isEmpty);
    });
  });
}
