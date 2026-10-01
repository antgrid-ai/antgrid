/// The viewer half of the WebRTC surface, behind one seam.
///
/// Mirrors `screen_share_backend.dart` for the same reason: the viewer's state
/// machine — fingerprint verification, candidate buffering, teardown — has to be
/// provable under `flutter test`, and libwebrtc cannot load there. Everything
/// that touches the plugin is implemented once in `webrtc_screen_view_backend.dart`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'screen_share_backend.dart';

/// One inbound screen session: the answering peer connection, the rendered
/// remote video, and the two input datachannels the host opened.
abstract class ScreenViewPeer {
  /// Applies the host's offer and produces the answer, together with the
  /// fingerprint that answer will actually present in the DTLS handshake.
  Future<ScreenSdp> answerOffer(String offerSdp);

  Future<void> addRemoteCandidate(ScreenIceCandidate candidate);

  Stream<ScreenIceCandidate> get localCandidates;

  Stream<ScreenPeerState> get peerStates;

  /// The size the host is actually sending, emitted when the first frame
  /// renders and again on every resize. Authoritative over the offer's
  /// dimensions, which the host may have had to advertise as 1x1 before its
  /// encoder knew them.
  Stream<ScreenFrameSize> get frameSizes;

  /// The rendered remote video, or null before the first frame arrives.
  ///
  /// Owned by the peer rather than by a widget: the viewer surface is inside a
  /// desktop panel that reparents on every panel-mode toggle, and a renderer
  /// rebuilt from widget state would drop the texture each time.
  Widget? get videoView;

  /// Queues one input payload. [reliable] false picks the unordered, zero
  /// retransmit channel, which carries pointer motion only — a stale position is
  /// worse than a missing one. Returns false when the channel is not open yet,
  /// which is normal for the first samples after connecting.
  bool sendInput(String payload, {required bool reliable});

  /// The fingerprint of the certificate the host actually presented in the DTLS
  /// handshake, or null before one exists. The mirror of
  /// [ScreenSharePeer.remoteFingerprint], and checked against the sealed
  /// `screen:offer` for the same reason.
  Future<String?> remoteFingerprint();

  Future<void> dispose();
}

abstract class ScreenViewBackend {
  Future<ScreenViewPeer> createPeer();
}
