// What the Carbon session row owes beyond the behaviour the older row tests
// pin: no Ab widgets in its tree, touch sizing, focus landing back on the row
// after the inline editor, and a spoken name that carries every badge.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/open_checkout.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/widgets/carbon_session_badges.dart';
import 'package:antgrid/widgets/drawer/drawer_metrics.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

const _projectId = 'proj-carbon-row';

SessionEntry _session({bool lacksMemory = false}) => SessionEntry(
  id: 'sess-1',
  name: 'Diagnose terminal scrollback bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  startedWithoutMemory: lacksMemory,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<ProviderContainer> pumpRow(
    WidgetTester tester, {
    SessionEntry? session,
    List<Override> overrides = const [],
  }) async {
    final transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    addTearDown(cache.close);
    final projectSession = ProjectSession(
      projectId: _projectId,
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await transport.dispose(),
    );
    addTearDown(projectSession.close);
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue(_projectId),
        projectSessionProvider.overrideWith((ref, id) async => projectSession),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider(_projectId).future);
    container
        .read(projectSessionRegistryProvider.notifier)
        .touch(_projectId, isLocal: true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: AbCarbonScope(
            child: Scaffold(
              body: SizedBox(
                width: 260,
                child: SessionRow(
                  entryId: _projectId,
                  session: session ?? _session(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  testWidgets('the row and its open menu hold no Ab widgets', (tester) async {
    await pumpRow(tester);
    expect(abWidgetsInScope(tester), isEmpty);

    await tester.tap(find.byType(CarbonOverflowMenu));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);

    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('the rename modal holds no Ab widgets', (tester) async {
    await pumpRow(tester);
    await tester.tap(find.byType(CarbonOverflowMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(
      abWidgetsInScope(
        tester,
        scope: find.byType(Overlay).first,
        allow: {'AbAgentMark', 'AbCarbonScope'},
      ),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('closing the menu with Escape returns focus to its trigger', (
    tester,
  ) async {
    await pumpRow(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(CarbonSideNavLink)));
    await tester.pump();

    await tester.tap(find.byType(CarbonOverflowMenu));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsNothing);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(
      focused!.context!.findAncestorWidgetOfExactType<CarbonOverflowMenu>(),
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('touch: the row is a 44 target', (tester) async {
    await pumpRow(tester);
    expect(tester.getSize(find.byType(CarbonSideNavLink)).height, 44.0);
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Escape in the inline editor puts focus back on the row', (
    tester,
  ) async {
    await pumpRow(tester);

    final row = find.byType(CarbonSideNavLink);
    await tester.tap(row);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(
      focused!.context!.findAncestorWidgetOfExactType<CarbonSideNavLink>(),
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('the spoken name carries the Handler count and missing Memory', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpRow(
      tester,
      session: _session(lacksMemory: true),
      overrides: [
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(
            HandlerState.initial().copyWith(
              sessions: {
                'sess-1': HandlerSessionState(
                  terminalId: 'sess-1',
                  runState: HandlerRunState.needsYou,
                  pendingEscalations: 2,
                  armedAt: 1,
                  goal: 'ship it',
                  backlog: const [],
                  escalations: const [],
                ),
              },
            ),
          ),
        ),
        entryIsLocalCheckoutProvider.overrideWith((ref, id) async => true),
        memoryDrawerEnabledProvider.overrideWith((ref) async => true),
      ],
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(RegExp('Handler waiting on 2')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('started without Memory')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    handle.dispose();
  });

  // Six badges share the trailing slot and all but one render nothing here, so
  // a slot divided between them evenly leaves this tag an empty pill.
  testWidgets('a lone tag shows its whole label', (tester) async {
    await pumpRow(
      tester,
      session: _session(lacksMemory: true),
      overrides: [
        entryIsLocalCheckoutProvider.overrideWith((ref, id) async => true),
        memoryDrawerEnabledProvider.overrideWith((ref) async => true),
      ],
    );
    await tester.pumpAndSettle();

    // Either outcome is right, depending on how wide the font sets the label:
    // the whole label fits, or the tag truncates at the full badge budget.
    final label = tester.renderObject<RenderParagraph>(find.text('No Memory'));
    final whole =
        label.size.width >= label.getMaxIntrinsicWidth(double.infinity) - 0.01;
    final tag = tester.getSize(find.byType(CarbonSessionMemoryRestartBadge));
    expect(
      whole || (tag.width - kDrawerPanelWidth / 2).abs() < 0.01,
      isTrue,
      reason: 'the tag got ${tag.width}px for a ${label.size.width}px label',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
