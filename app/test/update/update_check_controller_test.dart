import 'dart:async';

import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/update/update_check_controller.dart';
import 'package:antgrid/update/update_check_result.dart';
import 'package:antgrid/update/update_install_controller.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/update_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const available = UpdateCheckResult(
    UpdateCheckStatus.available,
    version: '2.0.0',
    candidateId: '2',
  );

  ProviderContainer setup(
    FakeUpdateStrategy? strategy, {
    DateTime Function()? clock,
    SpyUpdateInstallController? install,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final container = ProviderContainer(
      overrides: [
        updateStrategyProvider.overrideWithValue(strategy),
        updateInstallControllerProvider.overrideWith(
          () => install ?? SpyUpdateInstallController(),
        ),
        if (clock != null) updateCheckClockProvider.overrideWithValue(clock),
        updateCheckTimeoutProvider.overrideWithValue(timeout),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('manual checks bypass throttle and pending-row shortcuts', () async {
    var now = DateTime(2026);
    final strategy = FakeUpdateStrategy(result: available)..skipPending = true;
    final c = setup(strategy, clock: () => now);
    final checker = c.read(updateCheckControllerProvider.notifier);
    expect(
      await checker.checkAutomatically(),
      UpdateCheckOutcome.updateAvailable,
    );
    expect(await checker.checkAutomatically(), UpdateCheckOutcome.none);
    expect((await checker.checkManually()).status, UpdateCheckStatus.available);
    expect(strategy.checks, 2);
    now = now.add(const Duration(minutes: 31));
    expect(await checker.checkAutomatically(), UpdateCheckOutcome.none);
    expect(strategy.checks, 2);
    expect(strategy.preparations, 1);
    expect(strategy.installs, 0);
  });

  for (final automaticFirst in [true, false]) {
    test(
      'simultaneous checks share detection; manual owns policy ($automaticFirst)',
      () async {
        final completion = Completer<UpdateCheckResult>();
        final strategy = FakeUpdateStrategy(
          policy: UpdateCheckOutcome.updateAvailableQuiet,
        )..onDetect = () => completion.future;
        final c = setup(strategy);
        final checker = c.read(updateCheckControllerProvider.notifier);
        final first = automaticFirst
            ? checker.checkAutomatically()
            : checker.checkManually();
        final second = automaticFirst
            ? checker.checkManually()
            : checker.checkAutomatically();
        final third = checker.checkManually();
        await Future<void>.delayed(Duration.zero);
        expect(strategy.checks, 1);
        completion.complete(available);
        final outcomes = await Future.wait([first, second, third]);
        expect(outcomes[automaticFirst ? 0 : 1], UpdateCheckOutcome.none);
        expect(strategy.policies, 0);
        expect(strategy.installs, 0);
        expect(c.read(updateAvailableProvider), isTrue);
      },
    );
  }

  test(
    'dismissal does not cancel a check or restore automatic handoff',
    () async {
      final completion = Completer<UpdateCheckResult>();
      final strategy = FakeUpdateStrategy(
        policy: UpdateCheckOutcome.updateAvailableQuiet,
      )..onDetect = () => completion.future;
      final c = setup(strategy);
      final checker = c.read(updateCheckControllerProvider.notifier);
      final automatic = checker.checkAutomatically();
      expect(checker.claimDialog(), isTrue);
      expect(checker.claimDialog(), isFalse);
      final manual = checker.checkManually();
      checker.releaseDialog();
      completion.complete(available);
      expect(await automatic, UpdateCheckOutcome.none);
      expect((await manual).status, UpdateCheckStatus.available);
      expect(strategy.installs, 0);
      expect(c.read(updateAvailableProvider), isTrue);
    },
  );

  test(
    'a pending update survives a transient failure; Retry checks again',
    () async {
      final strategy = FakeUpdateStrategy(result: available);
      final c = setup(strategy);
      final checker = c.read(updateCheckControllerProvider.notifier);
      await checker.checkManually();
      strategy.onDetect = () => Future.error(StateError('offline'));
      expect((await checker.checkManually()).status, UpdateCheckStatus.failed);
      expect(c.read(updateAvailableProvider), isTrue);
      strategy.onDetect = null;
      expect((await checker.checkManually()).version, '2.0.0');
      expect(strategy.checks, 3);
    },
  );

  test('preparation failure is retried and cannot claim up to date', () async {
    final strategy = FakeUpdateStrategy()
      ..onPrepare = () => Future.error(StateError('feed'));
    final c = setup(strategy);
    final checker = c.read(updateCheckControllerProvider.notifier);
    expect((await checker.checkManually()).status, UpdateCheckStatus.failed);
    strategy.onPrepare = null;
    expect((await checker.checkManually()).status, UpdateCheckStatus.upToDate);
    expect(strategy.preparations, 2);
  });

  testWidgets('timeout keeps the native request lease until it settles', (
    tester,
  ) async {
    final completion = Completer<UpdateCheckResult>();
    final strategy = FakeUpdateStrategy()..onDetect = () => completion.future;
    final c = setup(strategy, timeout: const Duration(seconds: 1));
    final checker = c.read(updateCheckControllerProvider.notifier);
    final request = checker.checkManually();
    await tester.pump(const Duration(seconds: 2));
    expect((await request).status, UpdateCheckStatus.failed);
    expect((await checker.checkManually()).status, UpdateCheckStatus.failed);
    expect(strategy.checks, 1);
    completion.complete(available);
    await tester.pump();
    strategy.onDetect = null;
    expect((await checker.checkManually()).status, UpdateCheckStatus.upToDate);
    expect(strategy.checks, 2);
  });

  for (final automatic in [false, true]) {
    test('disposal cancels an outstanding check deadline ($automatic)', () {
      fakeAsync((async) {
        final completion = Completer<UpdateCheckResult>();
        final strategy = FakeUpdateStrategy()
          ..onDetect = () => completion.future;
        final c = setup(strategy);
        final checker = c.read(updateCheckControllerProvider.notifier);
        final request = automatic
            ? checker.checkAutomatically()
            : checker.checkManually();
        Object? reply;
        unawaited(request.then((value) => reply = value));
        async.flushMicrotasks();
        expect(strategy.checks, 1);
        expect(async.nonPeriodicTimerCount, 1);

        c.dispose();
        async.flushMicrotasks();
        expect(async.nonPeriodicTimerCount, 0);
        expect(completion.isCompleted, isFalse);
        expect(
          reply,
          automatic ? UpdateCheckOutcome.none : UpdateCheckResult.failed,
        );
        // A late native reply must neither publish nor revive the disposed owner.
        completion.complete(available);
        async.flushMicrotasks();
        expect(async.nonPeriodicTimerCount, 0);
        expect(strategy.installs, 0);
      });
    });
  }

  for (final strategy in [null, FakeUpdateStrategy(activeBuild: false)]) {
    test(
      'unsupported builds do not prepare, check or install ($strategy)',
      () async {
        final c = setup(strategy);
        final checker = c.read(updateCheckControllerProvider.notifier);
        expect(
          (await checker.checkManually()).status,
          UpdateCheckStatus.unsupported,
        );
        expect(await checker.checkAutomatically(), UpdateCheckOutcome.none);
        expect(strategy?.checks ?? 0, 0);
        expect(strategy?.preparations ?? 0, 0);
      },
    );
  }

  test('an existing install prevents another detection and action', () async {
    final strategy = FakeUpdateStrategy(result: available);
    final c = setup(
      strategy,
      install: SpyUpdateInstallController(seed: const UpdateInstallWorking(20)),
    );
    final checker = c.read(updateCheckControllerProvider.notifier);
    expect(
      (await checker.checkManually()).status,
      UpdateCheckStatus.downloading,
    );
    expect(await checker.checkAutomatically(), UpdateCheckOutcome.none);
    expect(strategy.checks, 0);
  });
}
