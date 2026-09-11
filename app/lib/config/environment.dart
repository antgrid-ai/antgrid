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

  /// Self-hosted Umami — the same instance the marketing site reports to, on
  /// its own website id.
  static const String umamiUrl = 'https://wa.radhaai.com';

  /// Hand-mirrored in `web/src/ui/analytics.tsx`, deliberately: one Umami site
  /// for the whole app.antgrid.ai surface, the web app's pageviews beside this
  /// app's named events. Nothing spans both trees to check it, and neither side
  /// fails when it drifts — both keep answering 200 while the numbers quietly
  /// split in two, so changing the id in one place changes nothing.
  ///
  /// Empty outside release, which makes the beacon inert — the same convention
  /// as [sentryDsn].
  ///
  /// This is the app's half of a gate the website gets for free: there the
  /// tracker refuses to run unless `location.hostname` is one it was given, so
  /// a dev build is silent without a branch anywhere. Nothing refuses a host
  /// here, so a debug build would file every `flutter run` against the
  /// production numbers. Umami keys a site on this id rather than on the
  /// hostname in the payload, so staging needs an id of its own before it can
  /// be counted at all — and until there is one, counting it as nothing beats
  /// counting it as prod.
  static const String umamiWebsiteId = kReleaseMode
      ? 'bfb955b0-5839-4106-8856-b17106233619'
      : '';

  /// What Umami files these events under. Not an endpoint the app talks to —
  /// the app is served from nowhere; this is what puts its events beside the
  /// web app's pageviews in the one app.antgrid.ai site.
  static const String umamiHostname = 'app.antgrid.ai';

  static const String eventsApiUrl = kReleaseMode
      ? 'https://app.antgrid.ai'
      : 'https://app.staging.antgrid.ai';

  /// DSN for the self-hosted Sentry-compatible error tracker (errex).
  /// Empty by default — crash reporting is inert until a DSN is supplied at
  /// build time via `--dart-define=SENTRY_DSN=https://...`.
  static const String sentryDsn = String.fromEnvironment('SENTRY_DSN');

  static const String salesIqSupportUrl = String.fromEnvironment(
    'SALESIQ_SUPPORT_URL',
    defaultValue: 'https://antgrid.ai/support?chat=1&source=app',
  );
}
