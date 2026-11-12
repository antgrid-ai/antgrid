import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';

import '../utils/platform_utils.dart';

/// The one place Antgrid chooses how a Carbon surface looks.
///
/// Carbon White under a light palette and Gray 100 under a dark one, read from
/// the live app theme so a palette switch reaches open Carbon surfaces too.
/// Phones and tablets get touch density; desktops get compact. Density is a
/// platform decision, never a window-width one: a wide tablet stays touch.
class AbCarbonScope extends StatelessWidget {
  const AbCarbonScope({super.key, this.density, required this.child});

  /// Forces a density for this subtree, e.g. a touch-first desktop surface.
  final CarbonDensity? density;

  final Widget child;

  static CarbonDensity get platformDensity =>
      isMobilePlatform ? CarbonDensity.touch : CarbonDensity.compact;

  @override
  Widget build(BuildContext context) => CarbonTheme(
    data: CarbonThemeData.forBrightness(
      Theme.of(context).brightness,
      density: density ?? platformDensity,
    ),
    child: child,
  );
}
