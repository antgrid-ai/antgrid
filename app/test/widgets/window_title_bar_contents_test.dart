import 'dart:async';

import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_brand_mark.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

/// Compound `<machine>.<project>` registration id, const so it can be
/// `pumpAt`'s default.
const _focusedProjectId = 'agent-123.test-project';

final _testAgent = PairedAgent(
  relayUrl: 'wss://test.relay',
  agentDeviceId: _focusedProjectId,
  agentName: 'Test Agent',
);

/// A fake PairedAgentNotifier that returns a list with one mock PairedAgent.
///
/// Copied from `app_shell_test.dart` (a local class there, not exported).
class FakePairedAgentNotifier extends AsyncNotifier<List<PairedAgent>>
    implements PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => [_testAgent];

  @override
  Future<void> importCoordinates(dynamic qr) async {}
  @override
  Future<void> selectAgent(String agentDeviceId) async {}
  @override
  Future<void> forgetMachine(String agentDeviceIdOrUuid) async {}
  @override
  Future<void> retryAgentConnection() async {}
  @override
  void cancelActiveAgent() {}
}

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() {
    stores.close();
  });

  /// Pumps with a project focused by default, which is what puts the session
  /// controls in scope at all: with nothing focused the bar is the New Session
  /// screen's, and that route deliberately carries none of them (see
  /// `WindowTitleBarContents.build`). A test about the tiers would otherwise
  /// pass on the wrong reason — or fail while the tier logic is fine. Pass
  /// `projectId: null` to exercise that unfocused row itself.
  Future<void> pumpAt(
    WidgetTester tester,
    double width, {
    List<Override> extraOverrides = const [],
    String? projectId = _focusedProjectId,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          ...extraOverrides,
          pairedAgentProvider.overrideWith(() => FakePairedAgentNotifier()),
          selectedRegistrationIdProvider.overrideWith((ref) => projectId),
          // A focused id makes projectSessionProvider reachable — the handler
          // control resolves its service through serviceWhenReady — so hand
          // that session a transport instead of letting the real family look
          // for a folder and a socket.
          agentTransportForProvider.overrideWith(
            (ref, projectId) async => FakeAgentTransport(),
          ),
          terminalStateProvider.overrideWith(
            (ref) => Stream.value(const TerminalState()),
          ),
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(const HandlerState.initial()),
          ),
          windowChromeProvider.overrideWithValue(FakeWindowChrome()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WindowTitleBar(child: WindowTitleBarContents())),
        ),
      ),
    );
    await tester.pump();
  }

  /// Pumps with a sidebar control published, at the NARROW tier on purpose:
  /// that control is the only way back to a hidden drawer, so it must survive
  /// the width that drops the trailing row.
  Future<void> pumpSidebar(
    WidgetTester tester, {
    required bool hidden,
    required VoidCallback toggle,
  }) => pumpAt(
    tester,
    650,
    extraOverrides: [
      sidebarControlProvider.overrideWith(
        () => ValueController((hidden: hidden, toggle: toggle)),
      ),
    ],
  );

  testWidgets('shows the square brand mark, never the wordmark', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(find.byType(AbBrandMark), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('back and forward are disabled with empty history', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      // onTap == null is the design system's disabled contract — asserting
      // only that the buttons exist would pass even if they were live.
      AbIconButton buttonFor(String tooltip) => tester.widget<AbIconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(AbIconButton),
        ),
      );
      expect(buttonFor('Back').onTap, isNull);
      expect(buttonFor('Forward').onTap, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('at >=700px the handler control is present', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1200);
      expect(find.byKey(WindowTitleBarContents.handlerSlotKey), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'at exactly 700px the handler control is present (>= is inclusive)',
    (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await pumpAt(tester, 700);
        expect(
          find.byKey(WindowTitleBarContents.handlerSlotKey),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('below 700px the handler control and chip are hidden', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 650);
      expect(find.byKey(WindowTitleBarContents.handlerSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.chipSlotKey), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The session's name lives in the agent bar and NOWHERE else — rendering it
  // here too made a project id flash in this row before the name settled one
  // row down. Asserted with no agent bar mounted, the state that used to show
  // it, so no provider timing can bring it back.
  testWidgets('the title bar never names the session', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(find.byType(TitleBarBreadcrumb), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Unlike the name, these are controls: the modes that mount no agent bar
  // would otherwise leave the session with no mode switch and no handler. The
  // chip is machine-scoped, so it is deliberately NOT part of the handover.
  testWidgets('the session controls yield to a mounted agent bar', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(
        tester,
        1400,
        extraOverrides: [
          agentBarMountedProvider.overrideWith(() => ValueController(true)),
        ],
      );
      expect(find.byKey(WindowTitleBarContents.agentSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.modeSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.handlerSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.chipSlotKey), findsOneWidget);
      // Still no name, even in the state that hands the controls over.
      expect(find.byType(TitleBarBreadcrumb), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the session controls return with no agent bar mounted', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(find.byKey(WindowTitleBarContents.agentSlotKey), findsOneWidget);
      expect(find.byKey(WindowTitleBarContents.modeSlotKey), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The other side of the gate every session-control test leans on: with
  // nothing focused there is no session for an agent/mode/handler control to
  // speak for, and offering them would be offering controls over nothing. The
  // route-independent parts of the bar stay.
  testWidgets('the New Session row carries no session controls', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400, projectId: null);
      expect(find.byKey(WindowTitleBarContents.agentSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.modeSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.handlerSlotKey), findsNothing);
      expect(find.byKey(WindowTitleBarContents.searchSlotKey), findsOneWidget);
      expect(find.byType(AbBrandMark), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The bar's elastic middle carries the search on EVERY route — it answers
  // into its own popup, so unlike the panel controls it needs nothing on screen
  // to work against.
  testWidgets('the session search sits in the bar', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(find.byKey(WindowTitleBarContents.searchSlotKey), findsOneWidget);
      expect(find.text('Search sessions…'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The gutter, measured rather than recomputed: the search box is centred on
  // the whole bar, so at a tablet width it reaches back over the nav cluster
  // unless the reserve holds it off. Paint order alone wouldn't save the taps —
  // the field would still cover the buttons, just underneath them. 650px is the
  // tightest tier that still mounts the bar, which is where the reserve is
  // closest to yielding to the popup's own floor.
  testWidgets('the search box clears the nav cluster at the narrow tier', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 650);
      final forward = tester.getRect(
        find.ancestor(
          of: find.byTooltip('Forward'),
          matching: find.byType(AbIconButton),
        ),
      );
      final field = tester.getRect(
        find.byKey(WindowTitleBarContents.searchSlotKey),
      );
      expect(field.left, greaterThanOrEqualTo(forward.right));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Separate test, not a second pump — Riverpod forbids changing a live
  // scope's override COUNT.
  testWidgets('the session search survives a hidden drawer', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSidebar(tester, hidden: true, toggle: () {});
      expect(find.byKey(WindowTitleBarContents.searchSlotKey), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The slot itself always occupies its width — a control that comes and goes
  // there moves the centred search box between routes — so what must be absent
  // on a route publishing no control is the BUTTON, not the space. The width is
  // asserted too: an empty slot that doesn't measure the button's own footprint
  // reintroduces the drift with the button merely invisible.
  testWidgets('no sidebar control while no workspace is mounted', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(
        find.descendant(
          of: find.byKey(WindowTitleBarContents.sidebarSlotKey),
          matching: find.byType(AbIconButton),
        ),
        findsNothing,
      );
      expect(
        tester
            .getSize(find.byKey(WindowTitleBarContents.sidebarSlotKey))
            .width,
        AbTokens.iconButtonBox,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the sidebar control reads its CURRENT state and toggles', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      var toggled = 0;
      await pumpSidebar(tester, hidden: false, toggle: () => toggled++);

      expect(find.byTooltip('Hide projects'), findsOneWidget);
      // The other half of the reserved-slot pin: a published control occupies
      // exactly what the placeholder holds open, so the row's geometry — and
      // the search box centred on it — is the same on both kinds of route.
      expect(
        tester
            .getSize(find.byKey(WindowTitleBarContents.sidebarSlotKey))
            .width,
        AbTokens.iconButtonBox,
      );
      await tester.tap(find.byKey(WindowTitleBarContents.sidebarSlotKey));
      await tester.pump();
      expect(toggled, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Separate test, not a second pump: Riverpod forbids changing a live
  // ProviderScope's override COUNT, so re-pumping with a different sidebar
  // state has to start a fresh tree.
  testWidgets('a hidden drawer offers to show it', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSidebar(tester, hidden: true, toggle: () {});
      expect(find.byTooltip('Show projects'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the brand mark survives every tier', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 650);
      expect(find.byType(AbBrandMark), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Same as the sidebar slot on the other edge: reserved space, no button.
  testWidgets('no context panel control while no workspace is mounted', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(
        find.descendant(
          of: find.byKey(WindowTitleBarContents.contextPanelSlotKey),
          matching: find.byType(AbIconButton),
        ),
        findsNothing,
      );
      expect(
        tester
            .getSize(find.byKey(WindowTitleBarContents.contextPanelSlotKey))
            .width,
        AbTokens.iconButtonBox,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'the context panel control survives the narrow tier and toggles',
    (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        var toggled = 0;
        // 650px is below the 700px trailing tier — and hidden is the DEFAULT
        // panel mode at these widths, so dropping the control here would leave
        // no way to bring the context panel back.
        await pumpAt(
          tester,
          650,
          extraOverrides: [
            contextPanelControlProvider.overrideWith(
              () => ValueController((hidden: true, toggle: () => toggled++)),
            ),
          ],
        );
        expect(
          find.byKey(WindowTitleBarContents.contextPanelSlotKey),
          findsOneWidget,
        );
        expect(find.byTooltip('Show context panel'), findsOneWidget);
        await tester.tap(
          find.byKey(WindowTitleBarContents.contextPanelSlotKey),
        );
        await tester.pump();
        expect(toggled, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
