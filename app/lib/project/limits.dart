// Re-exported so existing `limits.dart` importers keep a single, canonical
// mobile check. The definition lives in `utils/platform_utils.dart`.
export '../utils/platform_utils.dart' show isMobilePlatform;

/// Maximum warm projects with **local-mode** agents on desktop. Each holds a
/// spawned agent process (~80 MB) so this is the resource-bound number.
const int kWarmCapLocal = 10;

/// Maximum warm **relay-mode** projects on desktop. Each is just an idle
/// WebSocket (~500 KB) so we can keep many more open. Gated only by the relay
/// connection limits.
const int kWarmCapRelay = 30;

/// Maximum warm projects on mobile foreground (all relay; mobile cannot spawn
/// local agents).
const int kWarmCapMobile = 3;

/// Effective warm cap for the current platform / mode mix.
///
/// On mobile: always [kWarmCapMobile]. On desktop: a project counts against
/// [kWarmCapLocal] if it's local-mode, else [kWarmCapRelay]. The cap is
/// applied per-bucket — local and relay don't share quota.
int warmCapForBucket({required bool isLocal, required bool isMobile}) {
  if (isMobile) return kWarmCapMobile;
  return isLocal ? kWarmCapLocal : kWarmCapRelay;
}

/// Hover threshold before a cold drawer row triggers prefetch.
const Duration kHoverPrefetchDelay = Duration(milliseconds: 300);

/// After the app backgrounds, the time we wait before demoting all warm
/// projects to cold. Mobile-only.
const Duration kMobileBackgroundDemoteDelay = Duration(seconds: 30);
