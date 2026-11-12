// What App Review does on an iPad with no machine: open the sample Scheduler,
// make a schedule, run one now and open its session. The 2.1(a) rejection was
// an error on this page, so every test also proves nothing red appears inside
// the Scheduler itself.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/demo_scheduler.dart';
import 'package:antgrid/demo/fixtures/demo_scheduler_fixtures.dart';
import 'package:antgrid/demo/fixtures/demo_workspace_fixtures.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/scheduler_timezone.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/screens/scheduler_screen.dart';
import 'package:antgrid/widgets/scheduler/scheduler_lanes.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

const _ipadPortrait = Size(820, 1180);
const _ipadLandscape = Size(1180, 820);
const _desktop = Size(1280, 800);

const _nightly = kDemoScheduleNightlyName;
const _deps = kDemoScheduleDepsName;

// The platform channel behind the real zone provider never answers inside
// FakeAsync, which would leave the sample's seed unresolved forever.
final _zone = [schedulerLocalTimezoneProvider.overrideWith((_) async => null)];

/// The demo never goes idle (its agent keeps scripting), so frames are pumped
/// for a bounded while instead of with pumpAndSettle.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpFor(WidgetTester tester, Duration total, Duration step) async {
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

Finder field(String hint) =>
    find.byWidgetPredicate(
      (w) => w is CarbonTextInput && w.placeholder == hint,
    );

/// An option of the screen's Schedules / Runs switcher.
Finder seg(String label) => find.descendant(
  of: find.byType(CarbonContentSwitcher<bool>),
  matching: find.text(label),
);

/// The header's New schedule control: icon-only on a phone-width pane, a
/// labelled button beside the title on a wide one.
Finder newSchedule() => find.byWidgetPredicate(
  (w) =>
      w is CarbonButton &&
      (w.semanticLabel == 'New schedule' || w.label == 'New schedule'),
);

Finder inScreen(Finder f) =>
    find.descendant(of: find.byType(SchedulerScreen), matching: f);

/// DemoFrame's strip is itself a banner, so every "nothing red" check is
/// scoped to the Scheduler, whose own banners and editor errors are Carbon
/// notifications.
void expectNothingRed() {
  expect(
    inScreen(
      find.byWidgetPredicate(
        (w) =>
            w is CarbonNotification && w.kind == CarbonNotificationKind.error,
      ),
    ),
    findsNothing,
  );
  expect(inScreen(find.text(kDemoRefusalText)), findsNothing);
  expect(inScreen(find.textContaining("didn't work")), findsNothing);
  expect(inScreen(find.text('Machine unavailable')), findsNothing);
  expect(
    inScreen(find.text('Connect a machine to schedule tasks')),
    findsNothing,
  );
  expect(inScreen(find.textContaining('offline')), findsNothing);
}

Future<ProviderContainer> openScheduler(
  WidgetTester tester, {
  Size size = _ipadPortrait,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = await pumpDemoApp(
    tester,
    enterDemo: true,
    size: size,
    extraOverrides: _zone,
  );
  enterDemoScheduler(container);
  await tester.pump();
  await tester.pump();
  await settle(tester);
  return container;
}

void iosTest(
  String description,
  Future<void> Function(WidgetTester tester) body, {
  TargetPlatform platform = TargetPlatform.iOS,
}) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> openRowMenu(WidgetTester tester, String name) async {
  final trigger = find.byWidgetPredicate(
    (w) => w is CarbonOverflowMenu && w.semanticLabel == 'Actions for $name',
  );
  await tester.ensureVisible(trigger);
  await tester.pump();
  await tester.tap(trigger);
  await settle(tester);
}

Future<void> runNow(WidgetTester tester, String name) async {
  await openRowMenu(tester, name);
  await tester.tap(find.text('Run now'));
}

void main() {
  iosTest('the sample Scheduler shows no error to a reviewer', (tester) async {
    await openScheduler(tester);

    expect(find.text(_nightly), findsWidgets);
    expect(find.text('Sample machine'), findsWidgets);
    expectNothingRed();

    // Past the screen's 5 s poll, which is where a bad row would surface.
    await pumpFor(tester, const Duration(seconds: 6), const Duration(seconds: 1));

    expect(find.text(_nightly), findsWidgets);
    expect(find.text('Sample machine'), findsWidgets);
    expectNothingRed();
  });

  iosTest('a schedule created in the sample appears in the list', (
    tester,
  ) async {
    await openScheduler(tester);

    await tester.tap(newSchedule());
    await settle(tester);
    await tester.enterText(field('Schedule name'), 'Review open PRs');
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is CarbonTextInput &&
            w.variant == CarbonTextInputVariant.multiline,
      ),
      'Review the open pull requests and summarise what needs attention.',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    final create = find.widgetWithText(CarbonButton, 'Create schedule');
    expect(tester.widget<CarbonButton>(create).onPressed, isNotNull);
    await tester.ensureVisible(create);
    await tester.pump();
    await tester.tap(create);
    await settle(tester);

    // The editor's own name field also matches the text, so prove it closed.
    expect(create, findsNothing);
    expect(find.text('Review open PRs'), findsWidgets);
    expectNothingRed();
  });

  iosTest('Run now adds a run that starts, then completes', (tester) async {
    await openScheduler(tester);

    await runNow(tester, _deps);
    // Below kDemoRunPreparing, so the run has not been bound to a session yet.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Starting'), findsWidgets);
    expect(find.text('View run'), findsWidgets);

    await pumpFor(
      tester,
      kDemoManualRunDuration + const Duration(seconds: 6),
      const Duration(seconds: 1),
    );

    expect(find.text('Completed'), findsWidgets);
    expectNothingRed();
  });

  iosTest('Open session reaches the session transcript', (tester) async {
    final container = await openScheduler(tester);

    await runNow(tester, _deps);
    // The run is bound once a poll lands after kDemoRunPreparing; the poll
    // period is 5 s at an unknown phase.
    await pumpFor(
      tester,
      kDemoRunPreparing + const Duration(seconds: 7),
      const Duration(seconds: 1),
    );

    await openRowMenu(tester, _deps);
    await tester.tap(find.text('Open session'));
    await settle(tester);

    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
    expect(container.read(activeSessionIdProvider), kDemoSessionCartId);
    expect(find.text('Project unavailable'), findsNothing);

    // Back to the Scheduler with the drawer's own writes.
    container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.scheduler);
    container
        .read(navControllerProvider.notifier)
        .commit(const NavLocation(surface: WorkbenchSurface.scheduler));
    await settle(tester);

    await tester.tap(seg('Runs'));
    await settle(tester);

    final response = await container
        .read(demoSchedulerBackendProvider)
        .request('scheduler.runs', {'scheduleId': kDemoScheduleSmokeId});
    final runs = (response['runs'] as List).cast<Map<String, dynamic>>();
    final id = runs.firstWhere((r) => r['status'] == 'completed')['id'];
    final open = find.byKey(ValueKey('scheduler-run-open-$id'));
    await tester.ensureVisible(open);
    await tester.pump();
    await tester.tap(open);
    await settle(tester);

    expect(container.read(activeSessionIdProvider), kDemoSessionCheckoutId);
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
  });

  iosTest('leaving the sample drops what was made in it', (tester) async {
    final container = await openScheduler(tester);

    await tester.tap(newSchedule());
    await settle(tester);
    await tester.enterText(field('Schedule name'), 'Throwaway schedule');
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is CarbonTextInput &&
            w.variant == CarbonTextInputVariant.multiline,
      ),
      'Look around and report back.',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    final create = find.widgetWithText(CarbonButton, 'Create schedule');
    await tester.ensureVisible(create);
    await tester.pump();
    await tester.tap(create);
    await settle(tester);
    // The editor's own name field also matches the text, so prove it closed.
    expect(create, findsNothing);
    expect(find.text('Throwaway schedule'), findsWidgets);

    exitDemoMode(container);
    await settle(tester);
    enterDemoScheduler(container);
    await settle(tester);

    expect(find.text('Throwaway schedule'), findsNothing);
    // Asserted beside the absence so a spinner or error screen cannot pass.
    expect(find.text(_nightly), findsWidgets);
  });

  iosTest('landscape iPad gets the wide layout with no error', (tester) async {
    await openScheduler(tester, size: _ipadLandscape);

    expect(find.byType(SchedulerLaneStrip), findsWidgets);
    expect(find.text(_nightly), findsWidgets);
    expectNothingRed();
  });

  iosTest('desktop gets the wide layout with no error', (tester) async {
    await openScheduler(tester, size: _desktop);

    expect(find.byType(SchedulerLaneStrip), findsWidgets);
    expect(find.text(_nightly), findsWidgets);
    expectNothingRed();
  }, platform: TargetPlatform.windows);
}
