import 'dart:async';

import 'package:antgrid/design/widgets/ab_brand_mark.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/value_controller.dart';
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

final _testAgent = PairedAgent(
  relayUrl: 'wss://test.relay',
  agentDeviceId: 'agent-123.test-project',
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

  Future<void> pumpAt(
    WidgetTester tester,
    double width, {
    List<Override> extraOverrides = const [],
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
          selectedRegistrationIdProvider.overrideWith((ref) => null),
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

  testWidgets('the brand mark survives every tier', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 650);
      expect(find.byType(AbBrandMark), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('no context panel control while no workspace is mounted', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpAt(tester, 1400);
      expect(
        find.byKey(WindowTitleBarContents.contextPanelSlotKey),
        findsNothing,
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
