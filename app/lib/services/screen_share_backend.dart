/// The native-capture and WebRTC surface the screen-share host needs, behind one
/// seam.
///
/// The state machine — consent, gating, revocation teardown — is the part that
/// must be provable, and none of it can run under `flutter test` if it reaches
/// libwebrtc directly. So everything that touches the plugin lives behind these
/// interfaces and is implemented once in `webrtc_screen_backend.dart`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// One capturable native window.
@immutable
class ScreenWindow {
  const ScreenWindow({
    required this.id,
    required this.title,
    this.thumbnail,
    this.minimised = false,
  });

  /// The capture source id, which is the OS window handle verbatim on every
  /// supported platform — so the window the user picked for capture is the same
  /// one input is injected into, with no correlation layer.
  final String id;
  final String title;

  /// Offered anyway, and restored on the machine before capture starts. Carried
  /// so both pickers can say so first: un-minimising someone's window is a
  /// visible change to their desktop, not a detail of ours.
  final bool minimised;

  /// Null until the OS delivers it. Thumbnails are always asynchronous: the
  /// enumeration returns zero bytes and the image arrives later on
  /// [ScreenShareBackend.windowUpdates].
  final Uint8List? thumbnail;
}

@immutable
class ScreenFrameSize {
  const ScreenFrameSize(this.width, this.height);

  final int width;
  final int height;

  /// A minimised window is not merely dark — libwebrtc collapses its capture to
  /// a single pixel and stops advancing the frame counter. Rendering that is a
  /// black rectangle the user cannot diagnose, so it is treated as a fault.
  bool get isCollapsed => width <= 1 || height <= 1;

  @override
  bool operator ==(Object other) =>
      other is ScreenFrameSize &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// A session description together with the DTLS fingerprint parsed out of it.
@immutable
class ScreenSdp {
  const ScreenSdp({required this.sdp, required this.dtlsFingerprint});

  final String sdp;
  final String dtlsFingerprint;
}

@immutable
class ScreenIceCandidate {
  const ScreenIceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  /// Empty is the end-of-candidates signal rather than a malformed value.
  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

/// Coarse peer-connection lifecycle. Only the transitions the host acts on —
/// the full `RTCPeerConnectionState` ladder is a plugin detail.
enum ScreenPeerState { connecting, connected, disconnected, failed, closed }

/// One live capture plus the peer connection carrying it.
abstract class ScreenSharePeer {
  String get windowTitle;

  /// Best-effort size known before the first frame is encoded. The authoritative
  /// value is [encodedFrameSize], which only exists once media flows.
  ScreenFrameSize get initialFrameSize;

  Future<ScreenSdp> createOffer();

  /// Throws if the answer is rejected; the caller treats that as a failed
  /// negotiation, not as a recoverable state.
  Future<void> acceptAnswer(String sdp);

  Future<void> addRemoteCandidate(ScreenIceCandidate candidate);

  Stream<ScreenIceCandidate> get localCandidates;

  Stream<ScreenPeerState> get peerStates;

  /// Raw datachannel payloads, merged across both input channels — the
  /// unordered one carrying pointer motion and the ordered one carrying clicks
  /// and keys. Decoding is left to the service so that parsing untrusted remote
  /// input stays testable without a peer connection.
  Stream<String> get inputMessages;

  /// Fires when the captured track ends — the user closed the window, or the OS
  /// revoked the capture.
  Stream<void> get captureEnded;

  /// The size the encoder is actually producing, or null before the first frame.
  /// This is what detects the minimised-window collapse; the negotiated size
  /// never changes on its own.
  Future<ScreenFrameSize?> encodedFrameSize();

  /// The fingerprint of the certificate the remote peer actually presented in
  /// the DTLS handshake, or null before one exists. Checking it against the
  /// sealed claim is what proves the media session is the one the sealed
  /// channel negotiated, rather than one the relay substituted.
  Future<String?> remoteFingerprint();

  Future<void> dispose();
}

abstract class ScreenShareBackend {
  /// Windows only — never screens. A full-desktop mode is out of scope by
  /// design, not merely unimplemented.
  Future<List<ScreenWindow>> listWindows();

  /// Late-arriving thumbnails and title changes for windows already returned by
  /// [listWindows], keyed by [ScreenWindow.id].
  Stream<ScreenWindow> get windowUpdates;

  Future<ScreenSharePeer> startShare(String windowId);

  Future<void> dispose();
}

/// The peer's remote certificate does not exist until the DTLS handshake
/// completes, which is not the same instant as the connection state reporting
/// connected — so both sides retry the check before giving up on it.
const Duration kFingerprintProbeInterval = Duration(milliseconds: 500);
const int kFingerprintProbeAttempts = 6;

/// The `sha-256 AB:CD:…` value from an SDP's `a=fingerprint` attribute, or null
/// when the SDP carries none.
///
/// Both peers put this inside the sealed signalling channel and check it against
/// what they negotiated; a mismatch means the relay rewrote the SDP, which is
/// the one signalling attack the E2E seal does not already cover (DTLS-SRTP is a
/// second crypto path beside it).
String? parseDtlsFingerprint(String sdp) {
  for (final line in sdp.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('a=fingerprint:')) continue;
    final value = trimmed.substring('a=fingerprint:'.length).trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Case- and whitespace-insensitive comparison of two fingerprints. Hex digits
/// are rendered in either case by different stacks, so a raw `==` would reject
/// matching fingerprints.
bool dtlsFingerprintsMatch(String a, String b) =>
    _normalizeFingerprint(a) == _normalizeFingerprint(b);

/// Compares the digests alone, ignoring the hash-algorithm token.
///
/// Used only against a fingerprint read back from the peer connection's
/// statistics, where the algorithm lives in a separate field that some platforms
/// leave empty. The digest is what identifies the certificate; requiring the
/// token to be present as well would turn a missing stats field into a refused
/// session.
bool dtlsFingerprintDigestsMatch(String a, String b) =>
    _fingerprintDigest(a) == _fingerprintDigest(b);

String _normalizeFingerprint(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

String _fingerprintDigest(String value) =>
    _normalizeFingerprint(value).split(' ').last;
