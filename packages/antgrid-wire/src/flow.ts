/** Per-channel flow control between the two ends of an E2E session. The Dart
 *  client hand-mirrors these in `packages/antgrid_relay_client/lib/src/flow.dart`;
 *  the two must stay in lockstep. */

/** Sealed bytes a sender may have in flight PER CHANNEL beyond what the peer
 *  has credited. Holds one max-size sealed fragment (1.4 MB + 28) with room to
 *  pipeline the next one as credits arrive; small enough that a control frame
 *  written behind a full preview window waits ≤ 2 MiB of link time. */
export const CHANNEL_WINDOW_BYTES = 2_097_152;

/** Sealed bytes a sender may have in flight PER SOCKET (both channels
 *  together). Bounds what a liveness frame written now sits behind, since
 *  neither client can read its socket buffer (Bun's client `bufferedAmount`
 *  reads 0; dart:io exposes nothing). Window + 1 MiB so control still flows
 *  while preview is full. Per peer: the relay→bridge socket fans in every app
 *  of the account, so k apps can hold k × this toward one bridge. */
export const SOCKET_INFLIGHT_BYTES = 3_145_728;

/** Receiver credits once this many uncredited bytes arrived on a channel.
 *  window/4: the sender keeps ≥ 3/4 window of headroom between credits. */
export const CREDIT_BATCH_BYTES = 524_288;

/** Non-advancing credits (nothing charged in between) after which a sender
 *  concludes its uncredited bytes were lost in transit and resyncs. */
export const WINDOW_RESYNC_CREDITS = 2;

/** Per-channel cap on plaintext bytes waiting in the send queue. A message
 *  that would push past it is dropped whole (fragment sets are never split).
 *  2 × MAX_TRANSFER_BYTES: one maximal transfer queued behind another. */
export const MAX_SEND_QUEUE_BYTES = 67_108_864;

/** nonce(12) + GCM tag(16): sealed length = utf8 plaintext length + this.
 *  Lets the sender check the window before sealing. */
export const SEAL_OVERHEAD_BYTES = 28;

/** A channel gate-blocked for this long with data queued is logged once. */
export const WINDOW_STALL_WARN_MS = 5_000;
