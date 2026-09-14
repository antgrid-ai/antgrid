import 'dart:async';
import 'dart:math';

import 'flow.dart';

/// One frame waiting to be sealed and written: a whole envelope JSON, or one
/// fragment of one.
class QueuedAppFrame {
  QueuedAppFrame({
    required this.channel,
    required this.streamId,
    required this.plaintext,
    required this.plaintextBytes,
    this.msgType,
  });

  final String channel;
  final String streamId;
  final String plaintext;

  /// utf8 length of [plaintext] — the number the window is charged in, once the
  /// seal overhead is added. Passed in rather than computed here so a multi-MB
  /// fragment is measured once, by the encoder's own counter.
  final int plaintextBytes;

  /// Diagnostic type for the capture tap; a fragment carries its parent's.
  final String? msgType;

  /// Completes when the frame LEFT the queue — handed to the socket, or
  /// dropped. Never completes with an error: almost every caller is
  /// fire-and-forget with no handler attached, so an error here would surface
  /// as an unhandled zone error rather than as a signal. Drops stay visible
  /// where they always were, in the capture tap.
  final done = Completer<void>();
}

/// Seals and writes one frame now. Returns the sealed length that reached the
/// wire, or null if the frame was dropped before it got there.
typedef SchedulerSink = Future<int?> Function(QueuedAppFrame frame);

/// The outbound half of one E2E session: per-channel FIFO queues drained by a
/// single loop, so exactly one frame is sealed at a time and a channel's frames
/// reach the socket in the order they were handed over. Sealing at dequeue
/// rather than at enqueue means a frame queued across a rekey goes out under
/// the keys live at that moment.
///
/// [window] and [socketCap] bound the sealed bytes a sender may have in flight
/// beyond what the peer has credited, per channel and per socket. Both null
/// means no gate at all: everything queued drains as fast as the sink accepts
/// it.
///
/// Session frames (liveness, handshake, credits) never pass through here. They
/// are written directly so they overtake any backlog, and are counted against
/// the window via [charge] without being gated by it.
class SendScheduler {
  SendScheduler({
    required SchedulerSink sink,
    this.window,
    this.socketCap,
    this.maxQueuedBytes = kMaxSendQueueBytes,
    void Function(String)? log,
    DateTime Function()? clock,
  }) : _sink = sink,
       _log = log,
       clock = clock ?? DateTime.now;

  final SchedulerSink _sink;
  final void Function(String)? _log;

  /// Test seam for the resync clock.
  DateTime Function() clock;

  /// Sealed bytes allowed in flight per channel; null disables the gate.
  int? window;

  /// Sealed bytes allowed in flight across both channels; null disables it.
  int? socketCap;

  /// Per-channel cap on queued plaintext. A message whose frames would push
  /// past it is refused whole by [enqueue].
  int maxQueuedBytes;

  /// Test-only seam: the drain loop parks while true and resumes on [kick].
  /// Not part of the supported API.
  bool hold = false;

  static const _channels = ['control', 'preview'];

  final Map<String, List<QueuedAppFrame>> _queues = {
    'control': <QueuedAppFrame>[],
    'preview': <QueuedAppFrame>[],
  };
  final Map<String, int> _queuedBytes = {'control': 0, 'preview': 0};

  /// Cumulative sealed bytes written on each channel this session.
  final Map<String, int> _sent = {'control': 0, 'preview': 0};

  /// The peer's cumulative consumed count, clamped to [_sent]. Banking an
  /// over-credit would let more than one window fly at once.
  final Map<String, int> _credited = {'control': 0, 'preview': 0};

  /// The raw cumulative value last seen, so a stale or duplicated credit is
  /// recognised even after [_credited] was clamped below it.
  final Map<String, int> _lastCreditSeen = {'control': 0, 'preview': 0};

  /// [_sent] as it stood when each credit arrived, oldest first. The resync
  /// rule reads the newest one old enough to be conclusive (see [credit]).
  final Map<String, List<({DateTime at, int sent})>> _anchors = {
    'control': [],
    'preview': [],
  };

  bool _draining = false;

  /// When each channel's head first failed to fit. Cleared when it fits or the
  /// queue empties; the stall log reads it.
  final Map<String, DateTime> blockedSince = {};

  final Set<String> _stallWarned = {};

  /// Sealed bytes written on [ch] that the peer has not credited yet.
  int unacked(String ch) => max(0, _sent[ch]! - _credited[ch]!);

  int totalUnacked() => unacked('control') + unacked('preview');

  ({int frames, int bytes}) queued(String ch) =>
      (frames: _queues[ch]!.length, bytes: _queuedBytes[ch]!);

  /// Queue [frames] and start draining. All-or-nothing: a fragment set that
  /// would push its channel past [maxQueuedBytes] is refused entirely, because
  /// half a transfer on the wire is worse than none.
  bool enqueue(List<QueuedAppFrame> frames) {
    if (frames.isEmpty) return true;
    final ch = frames.first.channel;
    assert(
      frames.every((f) => f.channel == ch),
      'one call carries one message, and a message picks one channel: the '
      'queues and their byte counts are per channel',
    );
    var adding = 0;
    for (final f in frames) {
      adding += f.plaintextBytes;
    }
    if (_queuedBytes[ch]! + adding > maxQueuedBytes) return false;
    _queues[ch]!.addAll(frames);
    _queuedBytes[ch] = _queuedBytes[ch]! + adding;
    kick();
    return true;
  }

  /// Count bytes written OUTSIDE the queue — session frames, which bypass the
  /// gate but not the accounting. A peer's drop report names only a channel and
  /// a byte count, so bytes the sender never charged would un-charge bytes it
  /// did and inflate the window.
  void charge(String ch, int sealedBytes) {
    _sent[ch] = _sent[ch]! + sealedBytes;
  }

  /// The relay reported it discarded [bytes] of this sender's frames on [ch].
  /// Those bytes are in the sent total and will never reach the peer's consumed
  /// count, so without this every drop shrinks the channel's window for the
  /// rest of the session.
  void uncharge(String ch, int bytes) {
    _sent[ch] = max(0, _sent[ch]! - bytes);
    // Nothing the peer counted can exceed what actually reached it.
    _credited[ch] = min(_credited[ch]!, _sent[ch]!);
    // The anchors were taken in the old count and the discarded bytes may have
    // been written before any of them; a later resync must not present the
    // same bytes as lost a second time.
    final anchors = _anchors[ch]!;
    for (var i = 0; i < anchors.length; i++) {
      anchors[i] = (at: anchors[i].at, sent: max(0, anchors[i].sent - bytes));
    }
    kick();
  }

  /// Accept the peer's cumulative consumed count for [ch]. Returns true when
  /// the window moved — because the credit advanced, or because a resync
  /// concluded that bytes still uncredited were lost.
  ///
  /// Cumulative rather than incremental, so a credit lost in transit costs
  /// nothing: the next one carries the same ground truth.
  bool credit(String ch, int consumedTotal) {
    var moved = false;
    if (consumedTotal > _lastCreditSeen[ch]!) {
      _lastCreditSeen[ch] = consumedTotal;
      _credited[ch] = min(consumedTotal, _sent[ch]!);
      moved = true;
    }
    final now = clock();
    final lost = _presumedLost(ch, now);
    if (lost > 0) {
      _log?.call('window resync on $ch: $lost uncredited bytes presumed lost');
      uncharge(ch, lost);
      moved = true;
    }
    _anchors[ch]!.add((at: now, sent: _sent[ch]!));
    if (moved) {
      _stallWarned.remove(ch);
      kick();
    }
    return moved;
  }

  /// Bytes an anchor at least [kWindowResyncAgeMs] old saw written that the
  /// peer has still not counted. The relay delivers a channel in order and the
  /// peer credits every liveness tick, so a credit generated two ticks after a
  /// write has counted it if it ever arrived; what is still missing was
  /// discarded somewhere no drop report covered. Session frames keep both
  /// counts moving on a channel, which is why this compares against what was
  /// written rather than asking whether credits advance. A false positive
  /// costs one extra window in flight, never data. Keep in lockstep with the
  /// bridge's send-scheduler.ts.
  int _presumedLost(String ch, DateTime now) {
    final anchors = _anchors[ch]!;
    var newestOld = -1;
    for (
      var i = 0;
      i < anchors.length &&
          now.difference(anchors[i].at).inMilliseconds >= kWindowResyncAgeMs;
      i++
    ) {
      newestOld = i;
    }
    if (newestOld < 0) return 0;
    // An older anchor can never say more than the newest conclusive one.
    anchors.removeRange(0, newestOld);
    return max(0, anchors[0].sent - _credited[ch]!);
  }

  /// Forget every counter on both channels — a new session credits from zero.
  /// The queues are untouched: frames held across a rekey are still owed.
  void resetWindows() {
    for (final ch in _channels) {
      _sent[ch] = 0;
      _credited[ch] = 0;
      _lastCreditSeen[ch] = 0;
      _anchors[ch]!.clear();
    }
    blockedSince.clear();
    _stallWarned.clear();
  }

  /// Drop everything queued and return it, so the caller can record the drops.
  /// Every returned frame's `done` is completed, never failed.
  List<QueuedAppFrame> clear() {
    final dropped = <QueuedAppFrame>[];
    for (final ch in _channels) {
      dropped.addAll(_queues[ch]!);
      _queues[ch]!.clear();
      _queuedBytes[ch] = 0;
    }
    blockedSince.clear();
    _complete(dropped);
    return dropped;
  }

  /// Drop the queued frames of one stream — it detached, so its backlog must
  /// not sit in a window the rest of the session needs. Same completion
  /// contract as [clear]: a caller awaiting a frame on a stream that goes away
  /// while the gate is shut must not wait forever.
  List<QueuedAppFrame> dropStream(String streamId) {
    final dropped = <QueuedAppFrame>[];
    for (final ch in _channels) {
      final q = _queues[ch]!;
      var freed = 0;
      q.removeWhere((f) {
        if (f.streamId != streamId) return false;
        dropped.add(f);
        freed += f.plaintextBytes;
        return true;
      });
      _queuedBytes[ch] = _queuedBytes[ch]! - freed;
      if (q.isEmpty) blockedSince.remove(ch);
    }
    _complete(dropped);
    return dropped;
  }

  /// Resume the drain loop. Safe to call at any time: there is only ever one
  /// loop, and a call while it is already running is a no-op.
  void kick() {
    unawaited(_run());
  }

  void _complete(List<QueuedAppFrame> frames) {
    for (final f in frames) {
      if (!f.done.isCompleted) f.done.complete();
    }
  }

  bool _fits(QueuedAppFrame f) {
    final need = f.plaintextBytes + kSealOverheadBytes;
    final w = window;
    final cap = socketCap;
    final chUnacked = unacked(f.channel);
    final total = totalUnacked();
    // The "nothing outstanding" arms are the deadlock guards: a frame larger
    // than a limit still goes when no bytes are in flight, or it could never go
    // at all.
    final chOk = w == null || chUnacked == 0 || chUnacked + need <= w;
    final sockOk = cap == null || total == 0 || total + need <= cap;
    return chOk && sockOk;
  }

  /// The next frame to write: control before preview, always, so a preview
  /// backlog never delays a control frame — and a blocked control head never
  /// delays preview.
  QueuedAppFrame? _pick() {
    for (final ch in _channels) {
      final q = _queues[ch]!;
      if (q.isEmpty) {
        blockedSince.remove(ch);
        _stallWarned.remove(ch);
        continue;
      }
      if (_fits(q.first)) {
        blockedSince.remove(ch);
        _stallWarned.remove(ch);
        return q.first;
      }
      _noteBlocked(ch);
    }
    return null;
  }

  void _noteBlocked(String ch) {
    final since = blockedSince[ch] ??= DateTime.now();
    if (_stallWarned.contains(ch)) return;
    final stalledMs = DateTime.now().difference(since).inMilliseconds;
    if (stalledMs < kWindowStallWarnMs) return;
    _stallWarned.add(ch);
    _log?.call(
      'send gate stalled on $ch for ${stalledMs ~/ 1000}s: '
      'unacked=${unacked(ch)} totalUnacked=${totalUnacked()} '
      'queued=${_queues[ch]!.length} frame(s)/${_queuedBytes[ch]} bytes',
    );
  }

  Future<void> _run() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        if (hold) return;
        final f = _pick();
        // Idle, or every head is gate-blocked; credit() and uncharge() kick
        // the loop again once the window reopens.
        if (f == null) return;
        _queues[f.channel]!.removeAt(0);
        _queuedBytes[f.channel] = _queuedBytes[f.channel]! - f.plaintextBytes;
        int? n;
        try {
          // The await is also the yield that lets a session frame written
          // meanwhile land between two app frames rather than behind all of
          // them.
          n = await _sink(f);
        } catch (_) {
          // A sink that throws must not strand the frames behind it, nor leave
          // this frame's `done` pending forever.
          n = null;
        }
        if (n != null) _sent[f.channel] = _sent[f.channel]! + n;
        if (!f.done.isCompleted) f.done.complete();
      }
    } finally {
      _draining = false;
    }
  }
}
