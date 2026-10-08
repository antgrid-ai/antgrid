import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_all/webview_all.dart';

import '../demo/demo_identity.dart';
import '../storage/preview_origin_owner_store.dart';
import '../util/ab_log.dart';

/// One loopback port a tab is about to load, and the machine+project opening it.
typedef PreviewAdmission = ({int port, String owner});

/// Clears website data on the default webview profile.
typedef PreviewWebsiteDataWipe = Future<WebViewDataClearingResult?> Function();

enum PreviewClearStatus { cleared, partial, failed, refused }

enum PreviewAdmitWipe { none, unknownHistory, ownerChanged }

class PreviewAdmitOutcome {
  const PreviewAdmitOutcome({
    required this.wipe,
    this.status,
    this.contestedPorts = const {},
  });

  const PreviewAdmitOutcome.none() : this(wipe: PreviewAdmitWipe.none);

  final PreviewAdmitWipe wipe;

  /// Null when [wipe] is [PreviewAdmitWipe.none].
  final PreviewClearStatus? status;

  /// Loopback ports whose recorded owner differed from the admitting one.
  final Set<int> contestedPorts;
}

PreviewClearStatus classifyClearResult(
  WebViewDataClearingResult? r,
  TargetPlatform platform,
) {
  // No webview platform is registered, so there is nothing to clear.
  if (r == null) return PreviewClearStatus.cleared;
  if (r.failures.isNotEmpty) return PreviewClearStatus.failed;
  // Also what a WebView2 runtime without Profile2 reports: every type
  // unsupported.
  if (r.clearedDataTypes.isEmpty) return PreviewClearStatus.failed;
  final expected = {...WebViewDataType.values};
  if (platform == TargetPlatform.windows) {
    // WebView2 documents ALL_SITE as containing ALL_DOM_STORAGE, which
    // contains SERVICE_WORKERS ("termination and deregistration"), so the
    // plugin reporting them unsupported there does not mean they survive:
    // https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2browsingdatakinds
    // sessionStorage dies with its document. Android's legacy fallback, by
    // contrast, really does keep service workers and IndexedDB.
    expected.removeAll(const {
      WebViewDataType.serviceWorkers,
      WebViewDataType.sessionStorage,
    });
  }
  return r.clearedDataTypes.containsAll(expected)
      ? PreviewClearStatus.cleared
      : PreviewClearStatus.partial;
}

/// Scopes preview website data to the machine+project that wrote it.
///
/// No platform clears a single origin, so every clear is global on the default
/// webview profile; the owner map in [PreviewOriginOwnerStore] only decides
/// WHEN one runs. Admissions and every clear share one queue, so two batches
/// can never interleave their reads and writes of the map.
class PreviewSiteData {
  PreviewSiteData({
    required this.store,
    required this.wipe,
    required this.isDemoMode,
    this.wipeTimeout = const Duration(seconds: 15),
    Duration? stragglerGrace,
    TargetPlatform Function()? platform,
  }) : stragglerGrace = stragglerGrace ?? wipeTimeout,
       _platform = platform ?? (() => defaultTargetPlatform);

  final PreviewOriginOwnerStore store;
  final PreviewWebsiteDataWipe wipe;
  final bool Function() isDemoMode;
  final Duration wipeTimeout;
  final Duration stragglerGrace;
  final TargetPlatform Function() _platform;

  final _wipes = ValueNotifier<int>(0);
  final _sources = <Map<int, String> Function()>[];
  final _retirements = <Future<void>, PreviewAdmission?>{};
  Future<void> _tail = Future<void>.value();
  Future<void>? _straggler;

  // Pages the current clear could not wait for: still being retired when it
  // started, or dropped after that. What they wrote may outlive the clear.
  List<PreviewAdmission>? _lateRetirements;

  // Moves on whenever the queue stops waiting for a timed-out clear, so that
  // clear's eventual success cannot write the map outside the queue.
  int _stragglerFence = 0;

  /// Bumps after every clear whose success live pages must react to.
  ValueListenable<int> get wipes => _wipes;

  /// Registers where open tabs report the origins they hold; returns the
  /// remover.
  VoidCallback addLiveOrigins(Map<int, String> Function() source) {
    _sources.add(source);
    return () => _sources.remove(source);
  }

  /// Registers a dropped controller's page teardown so a native clear never
  /// runs while that page can still write into the profile. [origin] is the
  /// port that page loaded and the owner it was admitted under.
  void trackRetirement(Future<void> retirement, {PreviewAdmission? origin}) {
    late final Future<void> tracked;
    tracked = retirement
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _retirements.remove(tracked));
    _retirements[tracked] = origin;
    if (origin != null) _lateRetirements?.add(origin);
  }

  /// Never throws.
  Future<PreviewAdmitOutcome> admit(List<PreviewAdmission> batch) =>
      _serial(() async {
        try {
          if (isDemoMode()) return const PreviewAdmitOutcome.none();
          final entries = <int, String>{
            for (final a in batch)
              if (!isDemoEntryId(a.owner)) a.port: a.owner,
          };
          if (entries.isEmpty) return const PreviewAdmitOutcome.none();

          final snap = await store.read();
          final contested = <int>{
            if (snap != null)
              for (final e in entries.entries)
                if (snap.containsKey(e.key) && snap[e.key] != e.value) e.key,
          };
          if (snap != null && contested.isEmpty) {
            await store.merge(entries);
            return const PreviewAdmitOutcome.none();
          }

          final status = await _runWipe(recordLateSuccess: true);
          final kind = snap == null
              ? PreviewAdmitWipe.unknownHistory
              : PreviewAdmitWipe.ownerChanged;
          if (status == PreviewClearStatus.failed) {
            // Unknown history stays absent, which already retries next time.
            if (snap != null) {
              await store.merge({
                for (final p in entries.keys)
                  p: PreviewOriginOwnerStore.unsettled,
              });
            }
          } else {
            await store.replace(_settled(entries));
            _wipes.value++;
          }
          return PreviewAdmitOutcome(
            wipe: kind,
            status: status,
            contestedPorts: contested,
          );
        } catch (e) {
          AbLog.error(
            'preview',
            'preview admission failed',
            fields: {'error': '$e'},
          );
          return const PreviewAdmitOutcome.none();
        }
      });

  /// Never throws.
  Future<PreviewClearStatus> clearManually() => _serial(() async {
    try {
      if (isDemoMode()) return PreviewClearStatus.refused;
      final status = await _runWipe(recordLateSuccess: true);
      if (status != PreviewClearStatus.failed) {
        await store.replace(_settled());
        _wipes.value++;
      }
      return status;
    } catch (e) {
      AbLog.error(
        'preview',
        'manual site data clear failed',
        fields: {'error': '$e'},
      );
      return PreviewClearStatus.failed;
    }
  });

  /// Runs in demo mode too: the profile is shared with the real previews.
  /// Throws [StateError] when the data may have survived.
  Future<void> clearForSignOut() => _serial(() async {
    final status = await _runWipe(recordLateSuccess: false);
    // Pages still open at sign-out can write after the clear, so the map is
    // left unknown rather than clean and the next admission clears again. It
    // also keeps account-derived owner ids off the disk.
    await store.forget();
    if (await store.read() != null) {
      throw StateError('preview origin owners survived sign-out');
    }
    if (status == PreviewClearStatus.failed) {
      throw StateError('preview website data not cleared');
    }
  });

  Future<T> _serial<T>(Future<T> Function() task) {
    final run = _tail.then((_) => task());
    _tail = run
        .then<void>((_) {}, onError: (Object _) {})
        .then((_) => _drainStraggler());
    return run;
  }

  // Future.timeout does not cancel the native clear, and a second native clear
  // must not overlap it. The wait is bounded because a clear that never
  // returns must not stall every later admission.
  Future<void> _drainStraggler() async {
    final straggler = _straggler;
    if (straggler == null) return;
    await straggler.timeout(
      stragglerGrace,
      onTimeout: () {
        _stragglerFence++;
      },
    );
    _straggler = null;
  }

  Future<void> _quiesce() async {
    if (_retirements.isEmpty) return;
    // A page can be dropped while earlier ones are still being waited for, so
    // wait until none is outstanding.
    Future<void> drain() async {
      while (_retirements.isNotEmpty) {
        await Future.wait(_retirements.keys.toList());
      }
    }

    try {
      await drain().timeout(
        wipeTimeout,
        onTimeout: () =>
            AbLog.warn('preview', 'webview retirement timed out'),
      );
    } catch (_) {}
  }

  Future<PreviewClearStatus> _runWipe({required bool recordLateSuccess}) async {
    await _quiesce();
    _lateRetirements = [
      for (final origin in _retirements.values)
        if (origin != null) origin,
    ];
    final raw = Future.sync(wipe);
    try {
      final result = await raw.timeout(wipeTimeout);
      return _report(result);
    } on TimeoutException {
      AbLog.error(
        'preview',
        'website data clear failed',
        fields: {'reason': 'timeout'},
      );
      final fence = _stragglerFence;
      _straggler = raw
          .then<PreviewClearStatus>(
            _report,
            onError: (Object e) {
              _logFailure(e);
              return PreviewClearStatus.failed;
            },
          )
          .then((s) async {
            if (!recordLateSuccess || s == PreviewClearStatus.failed) return;
            if (fence != _stragglerFence) return;
            await store.replace(_settled());
            _wipes.value++;
          });
      return PreviewClearStatus.failed;
    } catch (e) {
      _logFailure(e);
      return PreviewClearStatus.failed;
    }
  }

  void _logFailure(Object e) => AbLog.error(
    'preview',
    'website data clear failed',
    fields: {'error': '$e'},
  );

  PreviewClearStatus _report(WebViewDataClearingResult? result) {
    final status = classifyClearResult(result, _platform());
    if (result == null) return status;
    if (status == PreviewClearStatus.failed) {
      AbLog.error(
        'preview',
        'website data clear failed',
        fields: {
          if (result.failures.isEmpty)
            'reason': 'no data type cleared'
          else
            for (final e in result.failures.entries) e.key.name: e.value,
        },
      );
    } else if (status == PreviewClearStatus.partial) {
      AbLog.warn(
        'preview',
        'website data partly cleared',
        fields: {
          'kept': [
            for (final t in WebViewDataType.values)
              if (!result.clearedDataTypes.contains(t)) t.name,
          ].join(','),
        },
      );
    }
    return status;
  }

  /// The map a successful clear leaves: live origins, then [entries]. A port a
  /// page was retired from during the clear reads unsettled unless it is still
  /// attributed to that page's own owner, because the clear could not wait for
  /// that page and what it wrote may have survived.
  Map<int, String> _settled([Map<int, String> entries = const {}]) {
    final out = {..._liveOwners(), ...entries};
    for (final r in _lateRetirements ?? const <PreviewAdmission>[]) {
      if (out[r.port] != r.owner) {
        out[r.port] = PreviewOriginOwnerStore.unsettled;
      }
    }
    _lateRetirements = null;
    return out;
  }

  Map<int, String> _liveOwners() {
    final out = <int, String>{};
    for (final source in _sources) {
      try {
        for (final e in source().entries) {
          if (!isDemoEntryId(e.value)) out[e.key] = e.value;
        }
      } catch (_) {}
    }
    return out;
  }
}
