/// Provenance of this build, stamped by CI at compile time.
///
/// The version is CalVer-ish — `<major>.<days since Unix epoch>.<run number>`,
/// e.g. `1.20662.412` — so it carries no semantic meaning: a rising middle
/// component is a later day, not a feature release. The commit and build time
/// are deliberately NOT encoded in it (a hex sha is not a legal version
/// component in semver, App Store, or MSIX) and travel as their own defines.
///
/// pubspec's `version:` only applies to local builds, which report `dev`.
/// The stamping formula lives in `.github/workflows/build-desktop.yml`.
abstract final class BuildInfo {
  static const String version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: 'dev',
  );

  static const String commit = String.fromEnvironment(
    'GIT_SHA',
    defaultValue: 'local',
  );

  /// ISO-8601 UTC, empty for local builds.
  static const String builtAt = String.fromEnvironment('BUILD_TIME');

  /// One line for an about surface or a bug report: `1.20662.412 (0f3b1c)`.
  static String get summary =>
      builtAt.isEmpty ? '$version ($commit)' : '$version ($commit) $builtAt';
}
