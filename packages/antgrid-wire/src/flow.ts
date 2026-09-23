/** Per-channel flow control between the two ends of a peer connection. The Dart
 *  client hand-mirrors these in `packages/antgrid_relay_client/lib/src/flow.dart`;
 *  the two must stay in lockstep. */

/** Plaintext bytes a sender may have in flight PER CHANNEL beyond what the peer
 *  has credited. Holds one max-size fragment (1.4 MB) with room to pipeline
 *  the next one as credits arrive; small enough that a control frame written
 *  behind a full preview window waits ≤ 2 MiB of link time. */
export const CHANNEL_WINDOW_BYTES = 2_097_152;

/** Plaintext bytes a sender may have in flight across both channels on one peer
 * connection. Window + 1 MiB leaves headroom for control while preview is full. */
export const SOCKET_INFLIGHT_BYTES = 3_145_728;

/** Receiver credits once this many uncredited bytes arrived on a channel.
 *  window/4: the sender keeps ≥ 3/4 window of headroom between credits. */
export const CREDIT_BATCH_BYTES = 524_288;

/** How old a credit-time anchor must be before bytes it saw written, and the
 *  peer has still not counted, are presumed lost. Two liveness ticks: the peer
 *  credits at least once per tick and the the native record stream is ordered,
 *  so a credit generated this long after a write has counted it if it ever
 *  arrived. Time rather than a credit count, because byte-triggered credits
 *  land milliseconds apart on a fast link. */
export const WINDOW_RESYNC_AGE_MS = 40_000;

/** Per-channel cap on plaintext bytes waiting in the send queue. A message
 *  that would push past it is dropped whole (fragment sets are never split).
 *  2 × MAX_TRANSFER_BYTES: one maximal transfer queued behind another. */
export const MAX_SEND_QUEUE_BYTES = 67_108_864;

/** A channel gate-blocked for this long with data queued is logged once. */
export const WINDOW_STALL_WARN_MS = 5_000;
