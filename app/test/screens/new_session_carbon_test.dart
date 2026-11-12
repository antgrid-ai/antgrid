// Screen-level guard for the New Session canvas: one Carbon scope, no `Ab*`
// widget anywhere under it, and touch-sized targets. It spans every composition
// of the shell (phone drawer, touch tablet, narrow mouse desktop, wide mouse
// desktop) because the top bar and the list header swap places between them.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/widgets/new_session/new_session_content.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_summary.dart';
import 'package:antgrid/widgets/session_search_modal.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

RecentSessionRow _row(String name) => RecentSessionRow(
  session: SessionEntry(
    id: 'id-$name',
    name: name,
    createdAt: 0,
    lastUsedAt: 0,
    archived: false,
    running: false,
  ),
  origin: const RecentOrigin(
    isLocal: true,
    registrationId: 'antgrid',
    projectId: 'antgrid',
    machineUuid: null,
    projectName: 'antgrid',
    deviceName: 'this-device',
  ),
);

/// One composition of the shell's inputs to [NewSessionContent].
class _Layout {
  const _Layout(
    this.name, {
    required this.size,
    required this.platform,
    this.drawer = false,
    this.search = false,
  });

  final String name;
  final Size size;
  final TargetPlatform platform;
  final bool drawer;
  final bool search;

  bool get touch =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
}

const _layouts = [
  _Layout(
    'phone',
    size: Size(390, 844),
    platform: TargetPlatform.android,
    drawer: true,
  ),
  _Layout(
    'tablet',
    size: Size(1024, 768),
    platform: TargetPlatform.iOS,
    drawer: true,
  ),
  _Layout(
    'narrow desktop',
    size: Size(700, 800),
    platform: TargetPlatform.windows,
    search: true,
  ),
  _Layout('wide desktop', size: Size(1400, 900), platform: TargetPlatform.windows),
];

/// [testWidgets] that clears the platform override inside the body: the
/// binding checks foundation debug variables before any tearDown runs.
void testScreen(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, _Layout layout) async {
    debugDefaultTargetPlatformOverride = layout.platform;
    tester.view.physicalSize = layout.size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.reset();
      debugDefaultTargetPlatformOverride = null;
    });
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          recentSessionsProvider.overrideWithValue([
            _row('Refactor the relay'),
            _row('Ship the installer'),
          ]),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: NewSessionContent(
              onOpenDrawer: layout.drawer ? () {} : null,
              showSearchButton: layout.search,
            ),
          ),
        ),
      ),
    );
    // Bounded pumps: Carbon spinners never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionContent)),
    );
  }

  for (final layout in _layouts) {
    group(layout.name, () {
      testScreen('is one Carbon scope with no Ab widget under it', (
        tester,
      ) async {
        await pump(tester, layout);

        final scope = find.descendant(
          of: find.byType(NewSessionContent),
          matching: find.byType(AbCarbonScope),
        );
        expect(scope, findsOneWidget);
        expect(abWidgetsInScope(tester, scope: scope), isEmpty);
      });

      testScreen('top bar buttons match the layout', (tester) async {
        await pump(tester, layout);

        final menu = find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel == 'Open drawer',
        );
        expect(menu, layout.drawer ? findsOneWidget : findsNothing);
        expect(
          find.byType(SessionSearchButton),
          layout.drawer || layout.search ? findsOneWidget : findsNothing,
        );
      });

      if (layout.touch) {
        testScreen('every top bar button is a 44pt target', (tester) async {
          await pump(tester, layout);

          final buttons = find.descendant(
            of: find.byType(NewSessionContent),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is CarbonButton &&
                  (w.semanticLabel == 'Open drawer' ||
                      w.semanticLabel == 'Search sessions'),
            ),
          );
          expect(buttons, findsNWidgets(2));
          for (final e in buttons.evaluate()) {
            final size = tester.getSize(find.byWidget(e.widget));
            expect(size.width, greaterThanOrEqualTo(44));
            expect(size.height, greaterThanOrEqualTo(44));
          }
        });
      }
    });
  }

  testScreen('every target is 44pt on iOS', (tester) async {
    await pump(tester, _layouts[1]);

    final undersized = <String>[];
    for (final e in find
        .descendant(
          of: find.byType(NewSessionContent),
          matching: find.byType(CarbonButton),
        )
        .evaluate()) {
      final size = tester.getSize(find.byWidget(e.widget));
      if (size.height < 44) {
        undersized.add(
          '${(e.widget as CarbonButton).semanticLabel ?? (e.widget as CarbonButton).label}: $size',
        );
      }
    }
    expect(undersized, isEmpty);
  });

  testScreen('the phone group-by row is not clipped to a dense height', (
    tester,
  ) async {
    await pump(tester, _layouts[0]);

    expect(tester.takeException(), isNull);
    final switcher = find.byType(CarbonContentSwitcher<RecentGroupBy>);
    expect(switcher, findsOneWidget);
    expect(tester.getSize(switcher).height, greaterThanOrEqualTo(44));
  });

  testScreen('Esc on the canvas leaves New Session', (tester) async {
    await pump(tester, _layouts[2]);
    container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.newSession);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(container.read(workbenchSurfaceProvider), WorkbenchSurface.workspace);
  });
}
