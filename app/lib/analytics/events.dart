import 'package:flutter/foundation.dart' show TargetPlatform;

/// Maps a [TargetPlatform] to one of the platform tags the first-party
/// `/events` ingest accepts. Anything outside the known five (e.g.
/// [TargetPlatform.fuchsia]) becomes `'unknown'` so a fringe platform can never
/// fail the server's Zod enum and 400 the whole batch. Keep the returned values
/// in lockstep with the `platform` enum in web/src/routes/events.ts.
String analyticsPlatformTag(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return 'unknown';
  }
}

/// Canonical telemetry event names. Keep in lockstep with the web Zod enum in
/// web/src/routes/events.ts — a name here that the backend rejects is dropped.
abstract final class AnalyticsEvents {
  static const signInStarted = 'sign_in_started';
  static const signInCompleted = 'sign_in_completed';
  static const deviceProvisioned = 'device_provisioned';
  static const agentPaired = 'agent_paired';
  static const sessionOpened = 'session_opened';
  static const terminalUsed = 'terminal_used';
  static const fileExplorerOpened = 'file_explorer_opened';
  static const fileOpened = 'file_opened';
  static const previewOpened = 'preview_opened';
  static const sessionResumed = 'session_resumed';
  static const searchUsed = 'search_used';
  static const gitViewed = 'git_viewed';
  static const upgradeDialogShown = 'upgrade_dialog_shown';
  static const pricingViewed = 'pricing_viewed';
  static const checkoutOpened = 'checkout_opened';
  static const appActive = 'app_active';
}
