import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RelayNetTap;

import '../launcher/host_discovery.dart' show hostDir;
import 'jsonl_sink.dart';

/// The app's half of the relay frame capture.
///
/// Field-for-field mirror of `bridge/src/netwatch.ts`'s `NetwatchEvent`, kept in
/// lockstep BY HAND so the two JSONL streams merge with no translation step —
/// `antgrid watch --join` reads one file and one SSE snapshot and pairs them on
/// [frameId] alone. Same hand-mirroring convention as
/// `kCheckoutVariableMessageTypes` and `FRAME_VERSION`; the two drifting apart
/// is silent, and shows up only as a join that matches nothing.
///
/// This lives in `app/` and NOT in `packages/antgrid_relay_client` on purpose.
/// That package is Apache-2.0 and the boundary is one-way: the schema, the ring
/// and the file all stay ELv2, and the package sees only an untyped
/// [RelayNetTap] callback it may or may not have been given.
class NetwatchEvent {
  NetwatchEvent({
    required this.seq,
    required this.at,
    required this.dir,
    required this.kind,
    this.transport = 'relay',
    this.channel,
    this.streamId,
    this.msgType,
    this.bytes,
    this.frameId,
    this.reason,
    this.detail,
  });

  final int seq;
  final int at;

  /// `tx` | `rx`.
  final String dir;

  /// `sealed` | `handshake` | `control` | `drop`.
  final String kind;

  /// `relay` | `local`. The two are not the same wire — the relay path is
  /// sealed frames over a routed socket, the loopback path is plain JSON with
  /// no seal, no frames and no streams — so a capture that did not say which
  /// one it came from could be read as relay traffic it never was.
  ///
  /// This app records the relay wire in full and the loopback wire ONLY where
  /// it drops. The agent's `LocalListener` is the far end of the loopback
  /// socket and already sees every frame that crossed it; see
  /// `LocalTransport._dropped` for why recording them again here would double
  /// a merged capture.
  final String transport;

  final String? channel;
  String? streamId;

  /// Plaintext message type, filled in by [Netwatch.annotate] once the layer
  /// that knows it has run. Never a payload.
  String? msgType;

  final int? bytes;
  final String? frameId;

  /// Why a frame never left, or never reached dispatch. `kind == 'drop'` only.
  final String? reason;

  final Map<String, Object?>? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'seq': seq,
    'at': at,
    'dir': dir,
    'kind': kind,
    'transport': transport,
    // The bridge stamps nothing here; the CLI reads a missing origin as its
    // own. Explicit on this side so a merged capture stays self-describing
    // once a phone's events are relayed into the bridge's ring.
    'origin': 'app',
    if (channel != null) 'channel': channel,
    if (streamId != null) 'streamId': streamId,
    if (msgType != null) 'msgType': msgType,
    if (bytes != null) 'bytes': bytes,
    if (frameId != null) 'frameId': frameId,
    if (reason != null) 'reason': reason,
    if (detail != null && detail!.isNotEmpty) 'detail': detail,
  };
}

/// `true` when the capture is armed. Runtime env, not a `--dart-define`: an
/// intermittent connection fault has to be catchable without a rebuild.
bool get netwatchEnabled =>
    (Platform.environment['ANTGRID_NETWATCH'] ?? '').isNotEmpty;

/// Sibling of `host.log` and `app.log`, but its OWN file: `rotateLogIfNeeded`
/// keeps one 10 MiB generation, and a `terminal:output` flood sharing app.log
/// would roll real diagnostics off the end.
String netwatchLogPath({String? abDir}) =>
    '${hostDir(abDir: abDir)}/netwatch.log';

/// Records frames, holds each one briefly so the layer that knows its message
/// type can [annotate] it, then writes it out as JSONL.
///
/// The delay is what makes annotation possible at all. A frame's id (its
/// AES-GCM nonce) is readable only at the transport edge, and its plaintext
/// type only after decrypt — which on the inbound path is a real `await`
/// behind a per-channel chain. Rather than thread the id through four calls,
/// both layers name the same frame by id and this buffer joins them.
class Netwatch {
  Netwatch(
    this._sink, {
    int capacity = 512,
    Duration grace = const Duration(milliseconds: 250),
  }) : _capacity = capacity,
       _graceMs = grace.inMilliseconds;

  /// Null on a device with nowhere useful to write. `hostDir()` resolves from
  /// `USERPROFILE`/`HOME`, so a phone's capture has no reader on disk — it
  /// leaves through [subscribe] instead, up the same socket it describes.
  final JsonlSink? _sink;
  final int _capacity;
  final int _graceMs;

  /// Called once per event, at drain — after the annotation window, so a
  /// subscriber sees the message type the transport edge could not know.
  final _subscribers = <void Function(NetwatchEvent)>{};

  /// Insertion-ordered and drained from the front, so a plain list is the ring:
  /// [_capacity] bounds it under a flood, [_graceMs] bounds how long an event
  /// waits for an annotation that may never come.
  final List<NetwatchEvent> _pending = <NetwatchEvent>[];
  int _seq = 0;
  Timer? _timer;

  // Same reason as JsonlSink's: a live Timer outlives the widget tree and trips
  // the binding's "Timer is still pending after dispose" assertion. Tests drain
  // with flush() instead.
  static final bool _underTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  int get recorded => _seq;

  void record({
    required String dir,
    required String kind,
    String transport = 'relay',
    String? channel,
    String? streamId,
    String? msgType,
    int? bytes,
    String? frameId,
    String? reason,
    Map<String, Object?>? detail,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _pending.add(
      NetwatchEvent(
        seq: ++_seq,
        at: now,
        dir: dir,
        kind: kind,
        transport: transport,
        channel: channel,
        streamId: streamId,
        msgType: msgType,
        bytes: bytes,
        frameId: frameId,
        reason: reason,
        detail: detail,
      ),
    );
    _drainMatured(now);
    _scheduleDrain();
  }

  /// Traffic alone cannot drain the tail: the last frames before a stall would
  /// sit in the buffer forever, and a stall is the thing you are usually
  /// chasing. One pending timer, re-armed only while events are still held.
  void _scheduleDrain() {
    if (_underTest || _timer != null || _pending.isEmpty) return;
    _timer = Timer(Duration(milliseconds: _graceMs), () {
      _timer = null;
      _drainMatured(DateTime.now().millisecondsSinceEpoch);
      _scheduleDrain();
    });
  }

  /// Fill in what the transport edge could not know. A [frameId] no longer in
  /// the buffer is a no-op: the event has already been written and degrades to
  /// a typeless frame, which is honest — better than blocking a send to keep it
  /// annotatable.
  void annotate(String frameId, {String? msgType, String? streamId}) {
    // Newest first: a nonce repeat is a cryptographic impossibility, but a
    // reverse scan also finds the just-recorded frame in one step.
    for (var i = _pending.length - 1; i >= 0; i--) {
      final e = _pending[i];
      if (e.frameId != frameId) continue;
      if (msgType != null) e.msgType = msgType;
      if (streamId != null) e.streamId = streamId;
      return;
    }
  }

  /// Observe every event as it matures out of the annotation window. Returns
  /// the removal closure. A subscriber that throws is dropped from the call,
  /// never from the ring — the same observer contract the bridge's ring keeps.
  void Function() subscribe(void Function(NetwatchEvent) fn) {
    _subscribers.add(fn);
    return () => _subscribers.remove(fn);
  }

  void _drainMatured(int now) {
    while (_pending.isNotEmpty) {
      final oldest = _pending.first;
      if (_pending.length <= _capacity && now - oldest.at < _graceMs) break;
      _emit(_pending.removeAt(0));
    }
  }

  void _emit(NetwatchEvent e) {
    try {
      _sink?.add(jsonEncode(e.toJson()));
    } catch (_) {
      // `detail` arrives through an untyped map whose `cast` is a LAZY view, so
      // a non-String key or non-encodable value first throws HERE — a grace
      // period after the record, on a Timer stack that `tap`'s guard cannot
      // reach. Uncaught it becomes a zone error, i.e. a fatal
      // PlatformDispatcher.onError crash raised BY the observer. A malformed
      // map costs its line of capture; the subscribers below still run, so a
      // remote watcher is not silenced by a line it was never going to see.
    }
    // Snapshot: a subscriber may unsubscribe from inside its own callback.
    for (final fn in _subscribers.toList()) {
      try {
        fn(e);
      } catch (_) {
        // An observer must never be able to fail the path it observes.
      }
    }
  }

  /// Write every held event and push it to disk. Tests await this; nothing in
  /// the app does — a capture is read after the fact, and the grace window is
  /// short enough that a trailing frame or two costs nothing.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    while (_pending.isNotEmpty) {
      _emit(_pending.removeAt(0));
    }
    return _sink?.flush() ?? Future<void>.value();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _subscribers.clear();
    _sink?.dispose();
  }

  /// Adapter for the untyped callback the relay package calls. Two shapes:
  /// `op: 'frame'` records, `op: 'annotate'` fills in a type. Defensive by
  /// design — this is a boundary, and a malformed map must cost a line of
  /// capture, never a send.
  RelayNetTap get tap => (Map<String, Object?> event) {
    try {
      final frameId = event['frameId'] as String?;
      if (event['op'] == 'annotate') {
        if (frameId == null) return;
        annotate(
          frameId,
          msgType: event['msgType'] as String?,
          streamId: event['streamId'] as String?,
        );
        return;
      }
      final dir = event['dir'] as String?;
      final kind = event['kind'] as String?;
      if (dir == null || kind == null) return;
      record(
        dir: dir,
        kind: kind,
        transport: event['transport'] as String? ?? 'relay',
        channel: event['channel'] as String?,
        streamId: event['streamId'] as String?,
        msgType: event['msgType'] as String?,
        bytes: event['bytes'] as int?,
        frameId: frameId,
        reason: event['reason'] as String?,
        detail: (event['detail'] as Map?)?.cast<String, Object?>(),
      );
    } catch (_) {
      // Fail-open: an observer must never be able to fail the path it observes.
    }
  };
}

/// The process-wide capture, or null when nothing has armed one. Null is the
/// whole gate: nothing is constructed, no file is opened, and every tap handed
/// to the relay package stays null, so the instrumented paths cost one null
/// check — the id computation included, which is the only per-frame work.
Netwatch? _instance;
bool _resolved = false;

Netwatch? get netwatch {
  if (_resolved) return _instance;
  _resolved = true;
  if (netwatchEnabled) _instance = Netwatch(JsonlSink(netwatchLogPath()));
  return _instance;
}

/// The capture, creating a FILELESS one if the environment gate did not.
///
/// This is the remote path: a phone reads no environment and has no writable
/// `hostDir()`, so a capture it was ASKED for gets no sink and leaves through a
/// subscriber instead. A capture the environment already armed keeps its file —
/// the two arming routes share one recorder, so a desktop being watched both
/// ways records each frame once.
Netwatch ensureNetwatch() {
  // Through the getter, never `_instance` directly: the environment gate may
  // not have been consulted yet, and answering it here with a fileless recorder
  // would silently cost a desktop the netwatch.log it asked for.
  final armed = netwatch;
  if (armed != null) return armed;
  return _instance = Netwatch(null);
}

/// The capture tap for one project's loopback transport, or null when unarmed.
///
/// Two things it adds over [Netwatch.tap]. It stamps `detail.project`, because
/// one recorder serves the whole process while a `LocalTransport` is per
/// project — without it a capture with two projects open interleaves two
/// conversations with nothing to tell them apart, and the agent's
/// `LocalListener` stamps the same field on its own half so the two read as
/// one. And it is gated on the environment alone: unlike a relay socket, a
/// loopback transport is unreachable from `netwatch:configure` (the remote arm
/// holds a `RelayService`, not this), so there is no later route to arm it.
RelayNetTap? localNetTapFor(String projectId) {
  if (!netwatchEnabled) return null;
  final tap = ensureNetwatch().tap;
  return (Map<String, Object?> event) {
    try {
      final detail = <String, Object?>{
        ...?(event['detail'] as Map?)?.cast<String, Object?>(),
        'project': projectId,
      };
      tap({...event, 'detail': detail});
    } catch (_) {
      // The same fail-open `tap` keeps, restated because this runs OUTSIDE it:
      // the spread forces the lazy `cast` view, so a malformed `detail` throws
      // here, on the caller's own send/receive stack, before `tap` is reached.
    }
  };
}

/// Test seam: install a capture regardless of the environment gate, or clear
/// one. Mirrors `AbLog.configureForTest`.
void configureNetwatchForTest(Netwatch? instance) {
  _instance?.dispose();
  _instance = instance;
  _resolved = true;
}
