import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_dialog_surface.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/design/widgets/ab_progress_rule.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/subscription.dart';
import 'package:antgrid/update/update_check_controller.dart';
import 'package:antgrid/update/update_check_result.dart';
import 'package:antgrid/update/update_install_controller.dart';
import 'package:antgrid/update/update_status_dialog.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/widgets/account_footer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/update_fakes.dart';

void main() {
  const available = UpdateCheckResult(
    UpdateCheckStatus.available,
    version: '2.0.0',
    candidateId: '2',
  );

  Future<
    ({
      ProviderContainer container,
      SpyUpdateInstallController install,
      BuildContext caller,
    })
  >
  pump(
    WidgetTester tester,
    FakeUpdateStrategy? strategy, {
    UpdateInstallState installState = const UpdateInstallIdle(),
  }) async {
    useInMemoryPrefs();
    final install = SpyUpdateInstallController(seed: installState);
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((_) async => null),
        subscriptionProvider.overrideWith((_) async => null),
        pricingCatalogProvider.overrideWith((_) async => null),
        updateStrategyProvider.overrideWithValue(strategy),
        updateInstallControllerProvider.overrideWith(() => install),
      ],
    );
    addTearDown(container.dispose);
    late BuildContext caller;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                caller = context;
                return const Align(
                  alignment: Alignment.bottomCenter,
                  child: AccountFooter(),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AccountFooter));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Check for updates…')).dy,
      lessThan(tester.getTopLeft(find.text('Version')).dy),
    );
    await tester.ensureVisible(find.text('Check for updates…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates…'));
    await tester.pumpAndSettle();
    expect(find.byType(AbMenu), findsNothing);
    expect(find.byType(UpdateStatusDialog), findsOneWidget);
    return (container: container, install: install, caller: caller);
  }

  testWidgets(
    'menu closes before the check; only a successful result claims up to date',
    (tester) async {
      final completion = Completer<UpdateCheckResult>();
      final strategy = FakeUpdateStrategy()..onDetect = () => completion.future;
      final h = await pump(tester, strategy);
      expect(find.text('Checking for updates…'), findsOneWidget);
      expect(find.byType(AbProgressRule), findsOneWidget);
      expect(find.text('You’re up to date'), findsNothing);
      expect(h.install.starts, 0);
      completion.complete(UpdateCheckResult.upToDate);
      await tester.pumpAndSettle();
      expect(find.text('You’re up to date'), findsOneWidget);
      expect(find.byType(AbProgressRule), findsNothing);
    },
  );

  testWidgets(
    'explicit action closes the dialog then uses the surviving caller',
    (tester) async {
      final strategy = FakeUpdateStrategy(result: available);
      final h = await pump(tester, strategy);
      expect(find.text('Version 2.0.0'), findsOneWidget);
      expect(strategy.installs, 0);
      expect(h.install.starts, 0);
      h.install.onStart = (context) {
        expect(context.mounted, isTrue);
        expect(Navigator.of(context).canPop(), isFalse);
      };
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(h.install.starts, 1);
      expect(h.install.confirmed, isTrue);
      expect(find.byType(UpdateStatusDialog), findsNothing);
      expect(strategy.installs, 0);
    },
  );

  testWidgets('Retry repeats detection without installing', (tester) async {
    final strategy = FakeUpdateStrategy(result: UpdateCheckResult.failed);
    final h = await pump(tester, strategy);
    expect(find.text('Couldn’t check for updates'), findsOneWidget);
    strategy.result = available;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    expect(strategy.checks, 2);
    expect(h.install.starts, 0);
  });

  testWidgets('repeated open calls share one dialog and detection', (
    tester,
  ) async {
    final completion = Completer<UpdateCheckResult>();
    final strategy = FakeUpdateStrategy()..onDetect = () => completion.future;
    final h = await pump(tester, strategy);
    await showUpdateStatusDialog(h.caller, h.container);
    expect(find.byType(UpdateStatusDialog), findsOneWidget);
    expect(strategy.checks, 1);
    completion.complete(available);
    await tester.pumpAndSettle();
  });

  for (final dismiss in ['Escape', 'Back', 'Outside', 'Close']) {
    testWidgets('$dismiss dismisses without canceling the check or installing', (
      tester,
    ) async {
      final completion = Completer<UpdateCheckResult>();
      final strategy = FakeUpdateStrategy()..onDetect = () => completion.future;
      final h = await pump(tester, strategy);
      switch (dismiss) {
        case 'Escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'Back':
          await tester.binding.handlePopRoute();
        case 'Outside':
          await tester.tapAt(const Offset(4, 4));
        case 'Close':
          await tester.tap(find.byTooltip('Close'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(UpdateStatusDialog), findsNothing);
      completion.complete(available);
      await tester.pumpAndSettle();
      expect(
        h.container.read(updateCheckControllerProvider).result?.status,
        UpdateCheckStatus.available,
      );
      expect(h.install.starts, 0);
      // The account trigger, not the disposed submenu, regains keyboard focus.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Help'), findsOneWidget);
    });
  }

  testWidgets(
    'Tab traversal reaches the update action and keyboard activation works',
    (tester) async {
      final h = await pump(tester, FakeUpdateStrategy(result: available));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(h.install.starts, 1);
    },
  );

  testWidgets('already running install displays progress without an action', (
    tester,
  ) async {
    final strategy = FakeUpdateStrategy(result: available);
    final h = await pump(
      tester,
      strategy,
      installState: const UpdateInstallWorking(30),
    );
    expect(find.text('Update in progress'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    expect(strategy.checks, 0);
    expect(h.install.starts, 0);
  });

  testWidgets('unsupported development builds explain availability', (
    tester,
  ) async {
    await pump(tester, FakeUpdateStrategy(activeBuild: false));
    expect(find.text('Updates unavailable'), findsOneWidget);
    expect(find.textContaining('Install a released build'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'compact dialog stays centered on mobile with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, FakeUpdateStrategy(result: available));
      final surface = tester.getRect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ConstrainedBox && widget.constraints.maxWidth == 380,
          ),
        ),
      );
      expect(surface.left, greaterThanOrEqualTo(16));
      expect(surface.right, lessThanOrEqualTo(304));
      expect(surface.center.dx, closeTo(160, 1));
      expect(surface.center.dy, closeTo(284, 1));
      expect(tester.takeException(), isNull);
      expect(find.byType(AbDialogSurface), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
