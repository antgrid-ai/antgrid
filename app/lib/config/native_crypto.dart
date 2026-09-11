import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show E2eTransportDart;
import 'package:cryptography_flutter/cryptography_flutter.dart'
    show FlutterAesGcm;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../util/ab_log.dart';
import 'cng_aes_gcm.dart';

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
/// `compute` isolate past ~10 KB where no plugin exists (Linux, so the work is
/// at least off the UI isolate) → the pure Dart cipher in-isolate for the small
/// control frames, where a channel hop would cost more than it saves.
///
/// Windows is the exception: `cryptography_flutter` declares no plugin there, so
/// [CngAesGcm] takes the frame straight to `bcrypt.dll`. It is probed rather
/// than assumed — see [CngAesGcm.probe] — and any failure falls back to the same
/// [FlutterAesGcm] every other platform gets. Linux keeps the package default;
/// its equivalent (`libcrypto.so.3` over `dlopen`) is a separate decision.
///
/// Scoped to the transport cipher on purpose. The handshake's Ed25519/X25519/
/// HKDF stay on their Dart implementations: they run a handful of times per
/// connection, so they are not worth a behavioural risk in the bytes the bridge
/// verifies a transcript signature over.
void installNativeE2eCipher() {
  if (defaultTargetPlatform == TargetPlatform.windows && CngAesGcm.probe()) {
    E2eTransportDart.useAlgorithm(CngAesGcm());
    AbLog.info('NativeCrypto', 'transport cipher: CNG (bcrypt.dll)');
    return;
  }
  E2eTransportDart.useAlgorithm(FlutterAesGcm(secretKeyLength: 32));
  AbLog.info('NativeCrypto', 'transport cipher: cryptography_flutter');
}

/// Release the per-key state the installed native cipher is holding.
///
/// Call wherever a session's key material is retired. `SessionKeys.zeroize`
/// reaches only the Dart-side buffers; a cipher installed through
/// `E2eTransportDart.useAlgorithm` keeps its own copy so that a stateless
/// transport does not pay key setup per frame — on Windows that is a raw key
/// copy plus CNG's expanded schedule, both in THIS process, not the kernel's.
///
/// Nothing retires them by itself once a session is down: eviction is by use,
/// and a torn-down session imports no further keys. Without this call they live
/// as long as the process, which is exactly the signed-out or idle-overnight
/// case where a crash dump is most likely to be taken.
///
/// The cache is process-wide rather than per-session, so a second machine's
/// live session pays one key import (~15 us) on its next frame. Teardowns are
/// rare enough that this is not a throughput question.
void retireNativeE2eCipherKeys() => CngAesGcm.evictImportedKeys();
