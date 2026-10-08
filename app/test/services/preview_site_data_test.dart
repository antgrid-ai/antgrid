import 'dart:async';

import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/services/preview_site_data.dart';
import 'package:antgrid/storage/preview_origin_owner_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_all/webview_all.dart' show WebViewDataClearingResult;

import '../helpers/fake_webview_platform.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  late WipeRecorder recorder;
  late PreviewOriginOwnerStore store;

  setUp(() {
    useInMemoryPrefs();
    recorder = WipeRecorder();
    store = PreviewOriginOwnerStore();
  });

  PreviewSiteData make({
    bool demo = false,
    Duration wipeTimeout = const Duration(seconds: 15),
    Duration? stragglerGrace,
  }) => PreviewSiteData(
    store: store,
    wipe: recorder.call,
    isDemoMode: () => demo,
    wipeTimeout: wipeTimeout,
    stragglerGrace: stragglerGrace,
    platform: () => TargetPlatform.android,
  );

  test('unknown history wipes once, records the batch and bumps wipes', () async {
    final site = make();
    final outcome = await site.admit([
      (port: 3000, owner: 'a'),
      (port: 4000, owner: 'b'),
    ]);

    expect(outcome.wipe, PreviewAdmitWipe.unknownHistory);
    expect(outcome.status, PreviewClearStatus.cleared);
    expect(recorder.calls, 1);
    expect(await store.read(), {3000: 'a', 4000: 'b'});
    expect(site.wipes.value, 1);
  });

  test('a matching owner never wipes', () async {
    await store.replace({3000: 'a'});
    final site = make();

    final outcome = await site.admit([(port: 3000, owner: 'a')]);

    expect(outcome.wipe, PreviewAdmitWipe.none);
    expect(recorder.calls, 0);
    expect(await store.read(), {3000: 'a'});
    expect(site.wipes.value, 0);
  });

  test('an unrecorded port in a known map records without wiping', () async {
    await store.replace({3000: 'a'});
    final site = make();

    final outcome = await site.admit([(port: 4000, owner: 'b')]);

    expect(outcome.wipe, PreviewAdmitWipe.none);
    expect(recorder.calls, 0);
    expect(await store.read(), {3000: 'a', 4000: 'b'});
  });

  test('a different or unsettled owner wipes and keeps only live origins '
      'plus the batch', () async {
    for (final recorded in ['a', PreviewOriginOwnerStore.unsettled]) {
      recorder.calls = 0;
      await store.replace({3000: recorded, 4000: 'x'});
      final site = make()..addLiveOrigins(() => {5000: 'c'});

      final outcome = await site.admit([(port: 3000, owner: 'b')]);

      expect(outcome.wipe, PreviewAdmitWipe.ownerChanged);
      expect(outcome.contestedPorts, {3000});
      expect(recorder.calls, 1);
      expect(await store.read(), {5000: 'c', 3000: 'b'});
    }
  });

  test('a live unsettled port survives a replace and contests its owner',
      () async {
    await store.replace({3000: 'a'});
    final site = make()
      ..addLiveOrigins(() => {5000: PreviewOriginOwnerStore.unsettled});

    await site.admit([(port: 3000, owner: 'b')]);
    expect((await store.read())![5000], PreviewOriginOwnerStore.unsettled);

    final outcome = await site.admit([(port: 5000, owner: 'c')]);
    expect(outcome.wipe, PreviewAdmitWipe.ownerChanged);
    expect(recorder.calls, 2);
  });

  test('two contested ports in one batch wipe once', () async {
    await store.replace({3000: 'a', 4000: 'a'});
    final site = make();

    final outcome = await site.admit([
      (port: 3000, owner: 'b'),
      (port: 4000, owner: 'b'),
    ]);

    expect(outcome.contestedPorts, {3000, 4000});
    expect(recorder.calls, 1);
  });

  test('admissions are serialized', () async {
    await store.replace({3000: 'a'});
    final site = make();
    recorder.gate = Completer<void>();

    final first = site.admit([(port: 3000, owner: 'b')]);
    final second = site.admit([(port: 3000, owner: 'c')]);
    await pumpEventQueue();
    expect(recorder.calls, 1);

    recorder.gate!.complete();
    await Future.wait([first, second]);
    expect(recorder.calls, 2);
    expect(await store.read(), {3000: 'c'});
  });

  test('concurrent admissions on a known map both record', () async {
    await store.replace({});
    final site = make();

    await Future.wait([
      site.admit([(port: 3000, owner: 'b')]),
      site.admit([(port: 4000, owner: 'c')]),
    ]);

    expect(await store.read(), {3000: 'b', 4000: 'c'});
  });

  test('a wipe waits for tracked retirements', () async {
    final site = make();
    final retirement = Completer<void>();
    site.trackRetirement(retirement.future);

    final admitted = site.admit([(port: 3000, owner: 'a')]);
    await pumpEventQueue();
    expect(recorder.calls, 0);

    retirement.complete();
    await admitted;
    expect(recorder.calls, 1);
  });

  test('a retirement tracked while a wipe waits on another is waited for '
      'too', () async {
    final site = make();
    final first = Completer<void>();
    final second = Completer<void>();
    site.trackRetirement(first.future);

    final admitted = site.admit([(port: 3000, owner: 'a')]);
    await pumpEventQueue();
    site.trackRetirement(second.future);
    first.complete();
    await pumpEventQueue();
    expect(recorder.calls, 0);

    second.complete();
    await admitted;
    expect(recorder.calls, 1);
  });

  test('a page retired during a wipe leaves its port unsettled unless its '
      'owner still holds it', () async {
    await store.replace({3000: 'a'});
    final live = {4000: 'p', 6000: 'p'};
    final site = make()..addLiveOrigins(() => live);
    final gate = recorder.gate = Completer<void>();

    final admitted = site.admit([(port: 3000, owner: 'b')]);
    await pumpEventQueue();
    expect(recorder.calls, 1);
    live.remove(4000);
    site.trackRetirement(Future.value(), origin: (port: 4000, owner: 'p'));
    site.trackRetirement(Future.value(), origin: (port: 6000, owner: 'p'));
    gate.complete();
    await admitted;

    expect(await store.read(), {
      3000: 'b',
      4000: PreviewOriginOwnerStore.unsettled,
      6000: 'p',
    });

    // Only the clear that ran alongside those pages accounts for them.
    await site.clearManually();
    expect(await store.read(), {6000: 'p'});
  });

  test('a timed-out wipe the queue stopped waiting for never writes', () async {
    final site = make(
      wipeTimeout: const Duration(milliseconds: 10),
      stragglerGrace: const Duration(milliseconds: 10),
    )..addLiveOrigins(() => {3000: 'machine-1.proj-1'});
    final gate = recorder.gate = Completer<void>();

    final outcome = await site.admit([(port: 3000, owner: 'machine-1.proj-1')]);
    expect(outcome.status, PreviewClearStatus.failed);
    recorder.gate = null;
    await site.clearForSignOut();
    expect(await store.read(), isNull);

    gate.complete();
    await pumpEventQueue();
    expect(await store.read(), isNull);
    expect(site.wipes.value, 0);
  });

  group('a failed wipe', () {
    Future<void> expectFailedAdmit(
      PreviewSiteData site, {
      required Map<int, String>? seed,
    }) async {
      final outcome = await site.admit([(port: 3000, owner: 'b')]);
      expect(outcome.status, PreviewClearStatus.failed);
      expect(site.wipes.value, 0);
      if (seed == null) {
        expect(await store.read(), isNull);
      } else {
        expect(await store.read(), {...seed, 3000: ''});
      }
    }

    for (final seed in <Map<int, String>?>[
      null,
      {3000: 'a', 4000: 'x'},
    ]) {
      final label = seed == null ? 'unknown history' : 'known map';

      test('marks known batch ports unsettled and leaves unknown history '
          'unknown ($label, partial failure)', () async {
        if (seed != null) await store.replace(seed);
        recorder.result = kOneFailureResult;
        await expectFailedAdmit(make(), seed: seed);
      });

      test('throwing wipe ($label)', () async {
        if (seed != null) await store.replace(seed);
        recorder.throwing = StateError('boom');
        await expectFailedAdmit(make(), seed: seed);
      });

      test('nothing cleared ($label)', () async {
        if (seed != null) await store.replace(seed);
        recorder.result = kAllUnsupportedResult;
        await expectFailedAdmit(make(), seed: seed);
      });

      test('timeout ($label)', () async {
        if (seed != null) await store.replace(seed);
        recorder.gate = Completer<void>();
        final site = make(
          wipeTimeout: const Duration(milliseconds: 10),
          stragglerGrace: const Duration(milliseconds: 10),
        );
        await expectFailedAdmit(site, seed: seed);
        recorder.gate!.complete();
        await pumpEventQueue();
      });
    }
  });

  test('a timed-out wipe holds the queue and records live owners when it '
      'later succeeds', () async {
    final site = make(
      wipeTimeout: const Duration(milliseconds: 10),
      stragglerGrace: const Duration(minutes: 1),
    )..addLiveOrigins(() => {3000: 'b'});
    recorder.gate = Completer<void>();

    final outcome = await site.admit([(port: 3000, owner: 'b')]);
    expect(outcome.status, PreviewClearStatus.failed);
    expect(await store.read(), isNull);

    final manual = site.clearManually();
    await pumpEventQueue();
    expect(recorder.calls, 1);

    recorder.gate!.complete();
    expect(await manual, PreviewClearStatus.cleared);
    expect(recorder.calls, 2);
    expect(await store.read(), {3000: 'b'});
    expect(site.wipes.value, greaterThanOrEqualTo(2));
  });

  test('a late success of a timed-out wipe records live owners and bumps',
      () async {
    final site = make(
      wipeTimeout: const Duration(milliseconds: 10),
      stragglerGrace: const Duration(minutes: 1),
    )..addLiveOrigins(() => {3000: 'b'});
    recorder.gate = Completer<void>();

    await site.admit([(port: 3000, owner: 'b')]);
    expect(site.wipes.value, 0);

    recorder.gate!.complete();
    await pumpEventQueue();
    expect(await store.read(), {3000: 'b'});
    expect(site.wipes.value, 1);
  });

  test('clearManually replaces with live owners and bumps', () async {
    await store.replace({3000: 'a', 4000: 'x'});
    final site = make()..addLiveOrigins(() => {3000: 'a'});

    expect(await site.clearManually(), PreviewClearStatus.cleared);

    expect(recorder.calls, 1);
    expect(await store.read(), {3000: 'a'});
    expect(site.wipes.value, 1);
  });

  test('a failed manual clear leaves the map alone', () async {
    await store.replace({3000: 'a', 4000: 'x'});
    recorder.result = kOneFailureResult;
    final site = make();

    expect(await site.clearManually(), PreviewClearStatus.failed);

    expect(await store.read(), {3000: 'a', 4000: 'x'});
    expect(site.wipes.value, 0);
  });

  test('clearManually in demo mode is refused without wiping', () async {
    final site = make(demo: true);

    expect(await site.clearManually(), PreviewClearStatus.refused);
    expect(recorder.calls, 0);
  });

  test('clearForSignOut wipes, forgets the map and does not bump', () async {
    await store.replace({3000: 'machine-1.proj-1'});
    final site = make();

    await site.clearForSignOut();

    expect(recorder.calls, 1);
    expect(await store.read(), isNull);
    expect(site.wipes.value, 0);
  });

  test('clearForSignOut failure throws and still forgets', () async {
    await store.replace({3000: 'machine-1.proj-1'});
    recorder.result = kOneFailureResult;
    final site = make();

    await expectLater(site.clearForSignOut(), throwsStateError);
    expect(await store.read(), isNull);
  });

  test('clearForSignOut runs in demo mode', () async {
    final site = make(demo: true);

    await site.clearForSignOut();

    expect(recorder.calls, 1);
  });

  group('classifyClearResult', () {
    final cases =
        <(String, WebViewDataClearingResult?, TargetPlatform, PreviewClearStatus)>[
          ('null', null, TargetPlatform.android, PreviewClearStatus.cleared),
          (
            'windows result on windows',
            kWindowsResult,
            TargetPlatform.windows,
            PreviewClearStatus.cleared,
          ),
          (
            'windows result on android',
            kWindowsResult,
            TargetPlatform.android,
            PreviewClearStatus.partial,
          ),
          (
            'android legacy',
            kAndroidLegacyResult,
            TargetPlatform.android,
            PreviewClearStatus.partial,
          ),
          (
            'one failure',
            kOneFailureResult,
            TargetPlatform.android,
            PreviewClearStatus.failed,
          ),
          (
            'all unsupported',
            kAllUnsupportedResult,
            TargetPlatform.windows,
            PreviewClearStatus.failed,
          ),
          (
            'complete',
            kCompleteResult,
            TargetPlatform.macOS,
            PreviewClearStatus.cleared,
          ),
        ];
    for (final c in cases) {
      test(c.$1, () => expect(classifyClearResult(c.$2, c.$3), c.$4));
    }
  });

  test('demo mode or a demo owner never wipes or writes', () async {
    await store.replace({3000: 'a'});

    final demo = make(demo: true);
    expect((await demo.admit([(port: 3000, owner: 'b')])).wipe,
        PreviewAdmitWipe.none);

    final real = make();
    final outcome = await real.admit([(port: 3000, owner: kDemoProjectId)]);
    expect(
      (await real.admit([(port: 3000, owner: 'dev-1.$kDemoProjectId')])).wipe,
      PreviewAdmitWipe.none,
    );

    expect(outcome.wipe, PreviewAdmitWipe.none);
    expect(recorder.calls, 0);
    expect(await store.read(), {3000: 'a'});
  });
}
