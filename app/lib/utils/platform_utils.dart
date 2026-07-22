import 'package:flutter/foundation.dart';

/// Whether the app is running on a mobile (phone/tablet) form factor.
///
/// Single source of truth for mobile detection across the app — also re-exported
/// from `project/limits.dart` for its warm-cap/layout callers. Web is treated as
/// non-mobile (desktop layout/caps), matching the prior behavior. Uses
/// [defaultTargetPlatform] so it remains testable via
/// [debugDefaultTargetPlatformOverride].
bool get isMobilePlatform {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => true,
    _ => false,
  };
}
