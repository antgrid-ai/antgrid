/// Flow-control constants for the sealed session, hand-mirrored from
/// `packages/antgrid-wire/src/flow.ts`. Keep the two in lockstep by value: a
/// sender's window and its peer's credit batch only agree because both ends
/// compile the same numbers, and nothing on the wire negotiates them.
library;

/// Sealed bytes a sender may have in flight PER CHANNEL beyond what the peer
/// has credited. Holds one maximal sealed fragment with room to pipeline the
/// next as credits arrive, and is small enough that a control frame written
/// behind a full preview window waits only this much link time.
const int kChannelWindowBytes = 2097152;

/// Sealed bytes a sender may have in flight PER SOCKET, both channels together.
/// Bounds what a liveness frame written now sits behind, since neither client
/// can read its socket buffer — `dart:io` exposes nothing, and Bun's client
/// `bufferedAmount` reads 0 however much is queued. One window plus 1 MiB, so
/// control still flows while preview is full.
const int kSocketInflightBytes = 3145728;

/// A receiver credits a channel once this many uncredited bytes have arrived on
/// it. A quarter of the window, so the sender keeps three quarters of a window
/// of headroom between credits.
const int kCreditBatchBytes = 524288;

/// How old a credit-time anchor must be before bytes it saw written, and the
/// peer has still not counted, are presumed lost. Two liveness ticks: the peer
/// credits at least once per tick and the relay delivers a channel in order, so
/// a credit generated this long after a write has counted it if it ever
/// arrived. Time rather than a credit count, because byte-triggered credits
/// land milliseconds apart on a fast link.
const int kWindowResyncAgeMs = 40000;

/// Per-channel cap on plaintext bytes waiting in the send queue. A message that
/// would push past it is dropped whole, since a fragment set is never split.
/// Two maximal transfers: one queued behind another.
const int kMaxSendQueueBytes = 67108864;

/// nonce(12) + GCM tag(16). A sealed frame is this much longer than its utf8
/// plaintext, which is what lets a sender check its window before sealing.
const int kSealOverheadBytes = 28;

/// A channel blocked at the send gate for this long with data queued is logged
/// once, so a peer that stops crediting reads as "alive but not crediting"
/// rather than as a dead socket.
const int kWindowStallWarnMs = 5000;
