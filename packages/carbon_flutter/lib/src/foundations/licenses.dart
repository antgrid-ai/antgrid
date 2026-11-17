import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds the notices for assets bundled with this package to Flutter's
/// [LicenseRegistry], so they appear in `showLicensePage` and `LicensePage`.
///
/// The SIL OFL 1.1 requires the licence to travel with the IBM Plex fonts and
/// Apache-2.0 requires the notice to travel with the Carbon icon geometry;
/// bundling the files is the distribution, and registering them makes them
/// reachable from the standard listing.
abstract final class CarbonLicenses {
  static const String fontsAsset =
      'packages/carbon_flutter/assets/fonts/OFL.txt';
  static const String iconsAsset =
      'packages/carbon_flutter/assets/licenses/carbon-icons-LICENSE.txt';

  static bool _registered = false;

  /// Registers both notices. Call once at startup; later calls do nothing, so
  /// the licence page never lists duplicates. Texts load lazily, when the
  /// registry is read, from [bundle] (default [rootBundle]).
  static void register({AssetBundle? bundle}) {
    if (_registered) return;
    _registered = true;
    final source = bundle ?? rootBundle;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const <String>[
        'IBM Plex Sans',
        'IBM Plex Mono',
      ], await source.loadString(fontsAsset));
    });
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const <String>[
        'Carbon icons (@carbon/icons)',
      ], await source.loadString(iconsAsset));
    });
  }

  /// Clears the registration latch. The registry itself cannot be emptied, so
  /// tests compare entry counts before and after.
  @visibleForTesting
  static void debugResetForTesting() => _registered = false;
}
