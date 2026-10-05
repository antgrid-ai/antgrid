import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/update/macos_appcast_update_service.dart';
import 'package:antgrid/update/macos_sparkle_update_service.dart';
import 'package:antgrid/update/update_check_controller.dart';
import 'package:antgrid/update/update_check_result.dart';
import 'package:antgrid/update/update_install_controller.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/update_fakes.dart';

class _Appcast extends MacosAppcastUpdateService {
  int checks = 0;
  @override
  Future<UpdateCheckResult> check() async {
    checks++;
    return const UpdateCheckResult(
      UpdateCheckStatus.available,
      version: '2.0.0',
      candidateId: '2',
    );
  }
}

class _ActiveMacStrategy extends MacosSparkleStrategy {
  _ActiveMacStrategy({required super.sparkle, required super.appcast});
  @override
  bool get active => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('dev.leanflutter.plugins/auto_updater');
  const events = MethodChannel('dev.leanflutter.plugins/auto_updater_event');
  const completion = MethodChannel('antgrid/sparkle_update_cycle');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> launches;
  late MacosSparkleUpdateService sparkle;

  Future<void> finishCycle() => messenger.handlePlatformMessage(
    completion.name,
    completion.codec.encodeMethodCall(const MethodCall('finished')),
    (_) {},
  );

  setUp(() {
    launches = [];
    sparkle = MacosSparkleUpdateService();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'checkForUpdates') {
        launches.add(call);
      }
      return true;
    });
  });
  tearDown(() {
    sparkle.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final choice in ['Remind Me Later', 'Skip This Version']) {
    testWidgets('$choice releases busy state and allows another update', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      );
      final appcast = _Appcast();
      final strategy = _ActiveMacStrategy(sparkle: sparkle, appcast: appcast);
      final container = ProviderContainer(
        overrides: [
          updateStrategyProvider.overrideWithValue(strategy),
          updateInstallControllerProvider.overrideWith(
            SpyUpdateInstallController.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(updateCheckControllerProvider.notifier);
      expect(
        (await controller.checkManually()).status,
        UpdateCheckStatus.available,
      );
      expect(launches, isEmpty);

      expect(await strategy.install(context), UpdateInstallResult.handedOff);
      await tester.pump();
      expect(sparkle.flowRunning, isTrue);
      expect(launches, hasLength(1));
      expect((launches.single.arguments as Map)['inBackground'], isFalse);
      expect(
        container.read(updateCheckControllerProvider).result?.status,
        UpdateCheckStatus.downloading,
      );
      expect(
        (await controller.checkManually()).status,
        UpdateCheckStatus.downloading,
      );
      expect(await strategy.install(context), UpdateInstallResult.notInstalled);
      expect(launches, hasLength(1));
      expect(appcast.checks, 1);

      // Both choices finish normally: no error or no-update event is emitted.
      await finishCycle();
      await tester.pump();
      expect(sparkle.flowRunning, isFalse);
      expect(
        container.read(updateCheckControllerProvider).result?.status,
        UpdateCheckStatus.available,
      );
      expect(container.read(updateAvailableProvider), isTrue);
      expect(
        (await controller.checkManually()).status,
        UpdateCheckStatus.available,
      );
      expect(appcast.checks, 2);

      expect(await strategy.install(context), UpdateInstallResult.handedOff);
      await tester.pump();
      expect(launches, hasLength(2));
      expect(sparkle.flowRunning, isTrue);
      await finishCycle();
      expect(sparkle.flowRunning, isFalse);
    }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
  }

  testWidgets('error callbacks cannot release a cycle before it finishes', (
    tester,
  ) async {
    await sparkle.configureFeed();
    await sparkle.startUpdate();
    await tester.pump();
    sparkle.onUpdaterError(UpdaterError('cancelled'));
    expect(sparkle.flowRunning, isTrue);
    await sparkle.startUpdate();
    expect(launches, hasLength(1));
    await finishCycle();
    expect(sparkle.flowRunning, isFalse);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('no-update rejection waits for cycle completion to unblock', (
    tester,
  ) async {
    await sparkle.configureFeed();
    var retractions = 0;
    final subscription = sparkle.noUpdateFound.listen((_) => retractions++);
    addTearDown(subscription.cancel);
    await sparkle.startUpdate();
    await tester.pump();
    sparkle.onUpdaterUpdateNotAvailable(null);
    await tester.pump();
    expect(retractions, 1);
    expect(sparkle.flowRunning, isTrue);
    await finishCycle();
    expect(sparkle.flowRunning, isFalse);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  test('a native launch failure releases the latch', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await sparkle.configureFeed();
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(code: 'updater_busy_or_unavailable');
    });
    await expectLater(sparkle.startUpdate(), throwsA(isA<PlatformException>()));
    expect(sparkle.flowRunning, isFalse);
  });

  testWidgets('disposal during an outstanding cycle tolerates completion', (
    tester,
  ) async {
    await sparkle.configureFeed();
    await sparkle.startUpdate();
    await tester.pump();
    sparkle.dispose();
    await finishCycle();
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
}
