import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show E2eTransportDart;
import 'package:cryptography_flutter/cryptography_flutter.dart'
    show FlutterAesGcm;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import 'webcrypto_aes_gcm.dart';

/// Route the E2E transport cipher at the OS crypto APIs.
///
/// Every relay frame is sealed/opened with AES-256-GCM, and a tunneled preview
/// response carries the whole asset through it — `package:cryptography`'s pure
/// Dart cipher does that at single-digit MB/s on the UI isolate, so a dev-server
/// page costs seconds of dropped frames on a weak tablet. [FlutterAesGcm] hands
/// the work to the platform (AES-NI / ARMv8 crypto extensions) instead.
///
/// The layering is the package's own and degrades on its own:
/// native method channel on Android/iOS/macOS for payloads past ~2 KB → a
/// `compute` isolate past ~10 KB where no plugin exists (Windows/Linux, so the
/// work is at least off the UI isolate) → the pure Dart cipher in-isolate for
/// the small control frames, where a channel hop would cost more than it saves.
///
/// Scoped to the transport cipher on purpose. The handshake's Ed25519/X25519/
/// HKDF stay on their Dart implementations: they run a handful of times per
/// connection, so they are not worth a behavioural risk in the bytes the bridge
/// verifies a transcript signature over.
void installNativeE2eCipher() {
  if (_useWebcryptoCipher && _lacksCryptographyFlutterPlugin) {
    E2eTransportDart.useAlgorithm(WebcryptoAesGcm());
    return;
  }
  E2eTransportDart.useAlgorithm(FlutterAesGcm(secretKeyLength: 32));
}

/// Opt in to the BoringSSL cipher on the platforms that have no plugin:
/// `--dart-define=WEBCRYPTO_E2E_CIPHER=true`. Off by default while the
/// BoringSSL build hook is being proven out in CI — see
/// `docs/spikes/webcrypto-cipher.md`.
const bool _useWebcryptoCipher = bool.fromEnvironment('WEBCRYPTO_E2E_CIPHER');

/// The two platforms `cryptography_flutter` declares no plugin for, and so the
/// only two where swapping in BoringSSL wins anything. Everywhere else its
/// method channel already reaches the OS, and this would trade a proven path
/// for an unproven one.
bool get _lacksCryptographyFlutterPlugin =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;
