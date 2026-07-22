import 'package:flutter/foundation.dart' show kReleaseMode;

/// Default cloud backend endpoints, selected by build mode.
///
/// Release builds target prod; debug/profile builds target staging. These are
/// only the *defaults* — both are overridable at the provider layer (a
/// `RELAY_URL` / `LICENSE_API_URL` dart-define, and for the relay an App
/// Settings value), which always win when present. See
/// `defaultRelayUrlProvider` and `licenseApiUrlProvider`.
abstract final class AppEnvironment {
  static const String relayUrl = kReleaseMode
      ? 'wss://relay.antgrid.ai'
      : 'wss://relay.staging.antgrid.ai';

  static const String licenseApiUrl = kReleaseMode
      ? 'https://app.antgrid.ai'
      : 'https://app.staging.antgrid.ai';

  static const String plausibleUrl = 'https://plausible.instructui.com';

  static const String plausibleDomain = kReleaseMode
      ? 'app.antgrid.ai'
      : 'app.staging.antgrid.ai';

  static const String eventsApiUrl = kReleaseMode
      ? 'https://app.antgrid.ai'
      : 'https://app.staging.antgrid.ai';

  /// DSN for the self-hosted Sentry-compatible error tracker (errex).
  /// Empty by default — crash reporting is inert until a DSN is supplied at
  /// build time via `--dart-define=SENTRY_DSN=https://...`.
  static const String sentryDsn = String.fromEnvironment('SENTRY_DSN');
}
