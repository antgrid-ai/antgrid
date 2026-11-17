import 'package:flutter/foundation.dart';

/// Where an attach is in the round trip. [staging] and [finishing] are the
/// request/response hops either side of the chunk stream and report no
/// fraction: a sub-chunk screenshot emits exactly one progress tick, so a
/// bar pinned at 0% for both hops is all a user would ever see of it.
///
/// [staging] also covers waiting for the connection: a phone back from the
/// file picker re-establishes before a byte is sent, and that can take seconds.
enum AttachPhase { staging, sending, finishing, done }

/// One model behind both attach surfaces (the terminal's upload strip and the
/// composer's attachment chip), so they cannot disagree on phase or wording.
@immutable
class AttachProgress {
  const AttachProgress({
    required this.fileName,
    required this.phase,
    this.sent = 0,
    this.total = 0,
  });

  const AttachProgress.staging(this.fileName)
    : phase = AttachPhase.staging,
      sent = 0,
      total = 0;

  /// From an upload's `onProgress(sent, total)`: every byte sent leaves only
  /// the bridge's confirmation, a wait of unknown length. Nothing sent yet is
  /// still staging — the loopback transport ticks `(0, total)` and then waits
  /// out the bridge's whole copy, which a frozen "0%" would misreport.
  const AttachProgress.tick({
    required this.fileName,
    required this.sent,
    required this.total,
  }) : phase = sent >= total
           ? AttachPhase.finishing
           : sent <= 0
           ? AttachPhase.staging
           : AttachPhase.sending;

  final String fileName;
  final AttachPhase phase;
  final int sent;
  final int total;

  /// Null while the size of the current step is unknown — see [AttachPhase].
  double? get fraction =>
      phase == AttachPhase.sending && total > 0 ? sent / total : null;

  String get label => phase == AttachPhase.sending
      ? '$fileName $status'
      : '$fileName · $status';

  /// [label] status first, for a surface narrow enough to cut the end off:
  /// what is cut is then part of the name, never where the attach is.
  String get statusFirstLabel => '$status · $fileName';

  String get status => switch (phase) {
    AttachPhase.staging => 'uploading…',
    // Floored: "100%" belongs to no sending tick — all bytes sent is finishing.
    AttachPhase.sending => '${((fraction ?? 0) * 100).floor()}%',
    AttachPhase.finishing => 'finishing…',
    AttachPhase.done => 'added',
  };
}
