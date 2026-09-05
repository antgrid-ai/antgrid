import 'dart:async';
import 'dart:convert';

import 'netwatch.dart';

/// Ships this app's half of the frame capture to the machine that asked for it.
///
/// The desktop writes `netwatch.log` and `antgrid watch --join` merges the two
/// files after the fact. A phone can do neither: `hostDir()` resolves from
/// `USERPROFILE`/`HOME`, so there is no file anyone will ever read, and there is
/// no UI or environment variable to arm one with. So the bridge asks
/// (`netwatch:configure`) and the answer comes back up the very socket being
/// captured (`netwatch:events`).
///
/// Three things that shape the whole design:
///
///  * **It rides the plane it is describing.** Every batch is itself a frame the
///    tap records, so an unfiltered uploader generates its own next batch
///    forever. [_kSelfType] is the cut.
///  * **It is not free, so it is bounded twice** — a per-batch cap and a byte
///    budget, both of which DROP rather than queue. A capture that costs the
///    session it is diagnosing has changed the thing it was measuring.
///  * **Nothing on the device can turn it off.** The arm therefore carries a
///    dead-man TTL: a watcher killed with SIGKILL sends no disarm, and without
///    the lapse a phone would upload every frame it sees indefinitely.
class NetwatchUploader {
  NetwatchUploader({
    required this.send,
    required this.onArmedChanged,
    Netwatch? recorder,
    this.flushEvery = const Duration(milliseconds: 500),
    this.maxPerBatch = 250,
    this.bytesPerSecond = 32 * 1024,
  }) : _recorder = recorder ?? ensureNetwatch();

  /// Delivers one batch payload — `{events, dropped?, sentAt}` — as the body of
  /// a `netwatch:events` message. Building the message is the caller's job: the
  /// uploader knows nothing about the wire.
  final void Function(Map<String, Object?> payload) send;

  /// Installs or clears the capture tap. Kept out of here because only the
  /// caller holds the `RelayService` this app is watching, and because a
  /// disarmed uploader must leave NOTHING on the frame path — a recorder still
  /// tapped but no longer read is the cost with none of the benefit.
  final void Function(bool armed) onArmedChanged;

  final Duration flushEvery;
  final int maxPerBatch;
  final int bytesPerSecond;

  final Netwatch _recorder;

  /// A batch is a `netwatch:events` frame; recording it would generate the next
  /// batch, which would generate the next. Filtering at drain (not at record)
  /// is what makes this reliable: the type arrives by annotation, and by drain
  /// the annotation has either landed or is never coming.
  static const String _kSelfType = 'netwatch:events';

  void Function()? _unsubscribe;
  Timer? _flushTimer;
  Timer? _ttlTimer;
  final _batch = <Map<String, Object?>>[];
  int _dropped = 0;
  bool _armed = false;

  /// Token bucket, in bytes. Two seconds of budget so a burst that fits the
  /// average passes intact instead of being clipped at every window edge.
  late double _tokens = _burst;
  int _lastRefillMs = DateTime.now().millisecondsSinceEpoch;

  double get _burst => bytesPerSecond * 2.0;

  bool get armed => _armed;

  /// Arm or disarm. [ttl] is a ceiling on how long an arm survives without
  /// being renewed; re-arming restarts it. A disarm is idempotent and is also
  /// what [dispose] does, so a torn-down connection cannot leave a capture
  /// running against a socket nobody is reading.
  void configure({required bool enabled, Duration? ttl}) {
    // Refused BEFORE the cancel below, not after: nothing on the device can
    // turn a capture off, so an arm with no expiry is the one thing this class
    // will not honour — and cancelling the live dead-man timer on the way to
    // refusing it would leave an already-armed uploader running forever.
    if (enabled && ttl == null) return;
    _ttlTimer?.cancel();
    _ttlTimer = null;
    if (!enabled) {
      _disarm();
      return;
    }
    if (ttl != null) {
      _ttlTimer = Timer(ttl, _disarm);
    }
    if (_armed) return;
    _armed = true;
    _unsubscribe = _recorder.subscribe(_onEvent);
    _flushTimer = Timer.periodic(flushEvery, (_) => _flush());
    onArmedChanged(true);
  }

  void _disarm() {
    _ttlTimer?.cancel();
    _ttlTimer = null;
    if (!_armed) return;
    _armed = false;
    _unsubscribe?.call();
    _unsubscribe = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    onArmedChanged(false);
    // One last batch, so whatever the watcher was looking at when it stopped
    // still arrives. Deliberately AFTER the tap is gone: nothing this send
    // records can be captured any more, so it cannot start the loop again.
    _flush();
    _batch.clear();
    _dropped = 0;
  }

  void _onEvent(NetwatchEvent e) {
    if (e.msgType == _kSelfType) return;
    if (_batch.length >= maxPerBatch) {
      _dropped++;
      return;
    }
    final json = e.toJson();
    final cost = jsonEncode(json).length;
    if (!_spend(cost)) {
      _dropped++;
      return;
    }
    _batch.add(json);
  }

  bool _spend(int cost) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _tokens = (_tokens + (now - _lastRefillMs) / 1000 * bytesPerSecond)
        .clamp(0.0, _burst)
        .toDouble();
    _lastRefillMs = now;
    if (_tokens < cost) return false;
    _tokens -= cost;
    return true;
  }

  void _flush() {
    if (_batch.isEmpty && _dropped == 0) return;
    final events = List<Map<String, Object?>>.from(_batch);
    final dropped = _dropped;
    _batch.clear();
    _dropped = 0;
    try {
      send({
        'events': events,
        if (dropped > 0) 'dropped': dropped,
        // The reader's clock is the bridge's. This is what lets it shift the
        // whole batch onto one timeline — see `Netwatch.ingestRemote`.
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // A capture must never be able to fail the connection it observes.
    }
  }

  void dispose() => _disarm();
}
