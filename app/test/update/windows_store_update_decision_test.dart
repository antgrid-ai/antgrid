import 'package:antgrid/update/windows_store_update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The pure reply→decision mappings, plus the thin service wrapper driven over
// a MOCKED `antgrid/store_update` channel. The runner's native side
// (windows/runner/store_update_channel.cpp) does not run under `flutter test`
// and StoreContext itself needs an MSIX-packaged Store install, so the mock
// standing in for it is the closest this suite can get to the real channel —
// which makes the strings it exchanges the contract worth pinning.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('antgrid/store_update');
  const codec = StandardMethodCodec();
  const service = WindowsStoreUpdateService();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Answers the next outbound call on the channel, cleared at test end.
  void mockChannel(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  // Delivers an INBOUND call, the direction the native progress callback
  // uses; the arguments value is the whole method-call argument, as on the wire.
  Future<void> emitNative(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      null,
    );
    await pumpEventQueue();
  }

  void onWindows() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  group('decideStoreUpdate', () {
    test('null reply (channel error path) → none', () {
      expect(decideStoreUpdate(null), StoreUpdateCheck.none);
    });

    test('empty map → none', () {
      expect(decideStoreUpdate({}), StoreUpdateCheck.none);
    });

    test('zero updates → none, even if mandatory is set', () {
      expect(
        decideStoreUpdate({'updateCount': 0, 'mandatory': true}),
        StoreUpdateCheck.none,
      );
    });

    test('updates pending, none mandatory → optional', () {
      expect(
        decideStoreUpdate({'updateCount': 2, 'mandatory': false}),
        StoreUpdateCheck.optional,
      );
    });

    test('updates pending, mandatory → mandatory', () {
      expect(
        decideStoreUpdate({'updateCount': 1, 'mandatory': true}),
        StoreUpdateCheck.mandatory,
      );
    });

    test('missing mandatory key defaults to optional', () {
      expect(decideStoreUpdate({'updateCount': 1}), StoreUpdateCheck.optional);
    });

    test('malformed updateCount type → none', () {
      expect(
        decideStoreUpdate({'updateCount': 'lots', 'mandatory': true}),
        StoreUpdateCheck.none,
      );
    });

    test('malformed mandatory type degrades to optional, not mandatory', () {
      expect(
        decideStoreUpdate({'updateCount': 1, 'mandatory': 'yes'}),
        StoreUpdateCheck.optional,
      );
    });

    test('an unmodelled key alongside the known ones is tolerated', () {
      // The native reply grows fields over time (`version` already did); one
      // the Dart side does not model must not turn into "no update".
      expect(
        decideStoreUpdate({
          'updateCount': 1,
          'mandatory': false,
          'version': '1.20677.173.0',
          'somethingNew': 42,
        }),
        StoreUpdateCheck.optional,
      );
    });
  });

  group('storeUpdateVersion', () {
    test('a four-part Store version comes back verbatim', () {
      expect(storeUpdateVersion({'version': '1.20677.173.0'}), '1.20677.173.0');
    });

    test('surrounding whitespace is trimmed', () {
      expect(storeUpdateVersion({'version': ' 1.2.3 '}), '1.2.3');
    });

    test('null reply → null', () {
      expect(storeUpdateVersion(null), isNull);
    });

    test('absent key → null', () {
      expect(storeUpdateVersion({'updateCount': 1}), isNull);
    });

    test('the empty string the native side sends for "unknown" → null', () {
      // "" is the contract's placeholder, not a version — rendering it would
      // leave an empty name in copy that promises one.
      expect(storeUpdateVersion({'version': ''}), isNull);
    });

    test('a non-string value → null, not a crash', () {
      expect(storeUpdateVersion({'version': 12}), isNull);
    });

    test('anything that is not dotted decimals → null', () {
      for (final raw in ['v1.2.3', '1.2.3-beta', 'unknown', '1..2', '.1']) {
        expect(storeUpdateVersion({'version': raw}), isNull, reason: raw);
      }
    });
  });

  group('decodeStoreInstallOutcome', () {
    test('each contract string maps to its outcome', () {
      expect(
        decodeStoreInstallOutcome('completed'),
        StoreInstallOutcome.completed,
      );
      expect(
        decodeStoreInstallOutcome('cancelled'),
        StoreInstallOutcome.cancelled,
      );
      expect(decodeStoreInstallOutcome('none'), StoreInstallOutcome.none);
    });

    test('anything outside the contract → null, never a throw', () {
      for (final raw in <Object?>[null, '', 'failed', 'Completed', 3, true]) {
        expect(decodeStoreInstallOutcome(raw), isNull, reason: '$raw');
      }
    });
  });

  group('WindowsStoreUpdateService.requestDownloadAndInstall', () {
    test(
      'each native success string reaches the caller as its outcome',
      () async {
        onWindows();
        for (final (reply, expected) in const <(String, StoreInstallOutcome)>[
          ('completed', StoreInstallOutcome.completed),
          ('cancelled', StoreInstallOutcome.cancelled),
          ('none', StoreInstallOutcome.none),
        ]) {
          mockChannel((call) async {
            expect(call.method, 'requestDownloadAndInstall');
            return reply;
          });
          expect(await service.requestDownloadAndInstall(), expected);
        }
      },
    );

    test(
      'an unrecognised string degrades to unavailable, not a throw',
      () async {
        onWindows();
        mockChannel((_) async => 'exploded');
        expect(
          await service.requestDownloadAndInstall(),
          StoreInstallOutcome.unavailable,
        );
      },
    );

    test('a null reply degrades to unavailable', () async {
      onWindows();
      mockChannel((_) async => null);
      expect(
        await service.requestDownloadAndInstall(),
        StoreInstallOutcome.unavailable,
      );
    });

    test('store_unavailable (no MSIX identity) → unavailable', () async {
      onWindows();
      mockChannel(
        (_) async => throw PlatformException(
          code: 'store_unavailable',
          message: 'StoreContext requires package identity',
        ),
      );
      expect(
        await service.requestDownloadAndInstall(),
        StoreInstallOutcome.unavailable,
      );
    });

    test('a missing native implementation → unavailable', () async {
      onWindows();
      mockChannel((_) async => throw MissingPluginException());
      expect(
        await service.requestDownloadAndInstall(),
        StoreInstallOutcome.unavailable,
      );
    });

    test('off Windows it answers unavailable without a channel call', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var calls = 0;
      mockChannel((_) async {
        calls++;
        return 'completed';
      });
      expect(
        await service.requestDownloadAndInstall(),
        StoreInstallOutcome.unavailable,
      );
      expect(calls, 0);
    });
  });

  group('WindowsStoreUpdateService.checkForUpdates', () {
    test('a pending update carries its version through', () async {
      onWindows();
      mockChannel((call) async {
        expect(call.method, 'checkForUpdates');
        return <Object?, Object?>{
          'updateCount': 1,
          'mandatory': true,
          'version': '1.20677.173.0',
        };
      });
      expect(
        await service.checkForUpdates(),
        const StoreUpdateStatus(
          check: StoreUpdateCheck.mandatory,
          version: '1.20677.173.0',
        ),
      );
    });

    test('an unusable version degrades to null, keeping the check', () async {
      onWindows();
      mockChannel(
        (_) async => <Object?, Object?>{'updateCount': 1, 'version': ''},
      );
      final status = await service.checkForUpdates();
      expect(status.check, StoreUpdateCheck.optional);
      expect(status.version, isNull);
    });

    test('a version on a no-update reply is not carried', () async {
      onWindows();
      mockChannel(
        (_) async => <Object?, Object?>{'updateCount': 0, 'version': '1.2.3.4'},
      );
      expect(await service.checkForUpdates(), StoreUpdateStatus.none);
    });

    test('a channel failure resolves to none, never a throw', () async {
      onWindows();
      mockChannel(
        (_) async => throw PlatformException(code: 'store_unavailable'),
      );
      expect(await service.checkForUpdates(), StoreUpdateStatus.none);
    });

    test('off Windows it answers none without a channel call', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var calls = 0;
      mockChannel((_) async {
        calls++;
        return <Object?, Object?>{'updateCount': 1};
      });
      expect(await service.checkForUpdates(), StoreUpdateStatus.none);
      expect(calls, 0);
    });
  });

  group('WindowsStoreUpdateService.downloadProgress', () {
    test('native ticks arrive in order, as whole percent', () async {
      final seen = <int>[];
      final sub = service.downloadProgress.listen(seen.add);
      addTearDown(sub.cancel);

      await emitNative('downloadProgress', 0);
      await emitNative('downloadProgress', 37);
      await emitNative('downloadProgress', 100);

      expect(seen, [0, 37, 100]);
    });

    test('a tick with nobody listening is dropped, not buffered', () async {
      // Unbuffered by design: the two consent dialogs are on screen for the
      // first ticks, and a late listener replaying them would paint a progress
      // rule that jumps backwards.
      await emitNative('downloadProgress', 11);

      final seen = <int>[];
      final sub = service.downloadProgress.listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen, isEmpty);

      await emitNative('downloadProgress', 22);
      expect(seen, [22]);
    });

    test('a malformed payload is ignored and the stream stays live', () async {
      final seen = <int>[];
      final sub = service.downloadProgress.listen(seen.add);
      addTearDown(sub.cancel);

      await emitNative('downloadProgress', 'half');
      await emitNative('downloadProgress', <String, Object?>{'percent': 50});
      await emitNative('downloadProgress', null);
      await emitNative('downloadProgress', double.nan);
      await emitNative('downloadProgress', double.infinity);
      expect(seen, isEmpty);

      await emitNative('downloadProgress', 55);
      expect(seen, [55]);
    });

    test('an inbound call for another method is ignored', () async {
      final seen = <int>[];
      final sub = service.downloadProgress.listen(seen.add);
      addTearDown(sub.cancel);

      await emitNative('somethingElse', 99);
      expect(seen, isEmpty);
    });

    test('an out-of-range tick is clamped rather than dropped', () async {
      final seen = <int>[];
      final sub = service.downloadProgress.listen(seen.add);
      addTearDown(sub.cancel);

      await emitNative('downloadProgress', -5);
      await emitNative('downloadProgress', 137);
      expect(seen, [0, 100]);
    });
  });
}
