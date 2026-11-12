import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';

import '../utils/platform_utils.dart';
import 'ab_tokens.dart';

/// The one place Antgrid chooses how a Carbon surface looks.
///
/// Carbon White under a light palette and Gray 100 under a dark one, read from
/// the live app theme so a palette switch reaches open Carbon surfaces too.
/// Phones and tablets get touch density; desktops get compact. Density is a
/// platform decision, never a window-width one: a wide tablet stays touch.
///
/// Touch follows Apple's text styles and a 44pt target rather than Carbon's
/// 16px/48px touch defaults, so a Carbon surface matches the rest of the app on
/// a phone. The sizes come from the fixed `AbTokens.apple*` set, not the
/// platform-resolved `font*` getters, because a forced touch density on a
/// desktop must still get Apple's scale.
class AbCarbonScope extends StatelessWidget {
  const AbCarbonScope({super.key, this.density, required this.child});

  /// Forces a density for this subtree, e.g. a touch-first desktop surface.
  final CarbonDensity? density;

  final Widget child;

  static CarbonDensity get platformDensity =>
      isMobilePlatform ? CarbonDensity.touch : CarbonDensity.compact;

  static CarbonTypography _appleTouchTypography() {
    TextStyle sans(double size, double line, FontWeight weight) => TextStyle(
      inherit: false,
      fontFamily: CarbonTypography.sansFamily,
      package: CarbonTypography.package,
      fontSize: size,
      height: line / size,
      fontWeight: weight,
      letterSpacing: 0,
      leadingDistribution: TextLeadingDistribution.even,
      textBaseline: TextBaseline.alphabetic,
    );
    const regular = FontWeight.w400;
    return CarbonTypography(
      label: sans(AbTokens.appleSubheadline, AbTokens.appleSubheadlineLine, regular),
      helper: sans(AbTokens.appleFootnote, AbTokens.appleFootnoteLine, regular),
      control: sans(AbTokens.appleBody, AbTokens.appleBodyLine, regular),
      body: sans(AbTokens.appleBody, AbTokens.appleBodyLine, regular),
      heading: sans(
        AbTokens.appleHeadline,
        AbTokens.appleHeadlineLine,
        FontWeight.w600,
      ),
      headingLarge: sans(AbTokens.appleTitle3, AbTokens.appleTitle3Line, regular),
      title: sans(AbTokens.appleTitle1, AbTokens.appleTitle1Line, regular),
      code: sans(AbTokens.appleSubheadline, AbTokens.appleSubheadlineLine, regular)
          .copyWith(
            fontFamily: CarbonTypography.monoFamily,
            letterSpacing: 0.32,
          ),
    );
  }

  static final CarbonTypography _touchTypography = _appleTouchTypography();

  @override
  Widget build(BuildContext context) => CarbonTheme(
    data: CarbonThemeData.forBrightness(
      Theme.of(context).brightness,
      density: density ?? platformDensity,
      touchTarget: AbTokens.tapTargetMin,
    ).copyWith(touchTypography: _touchTypography),
    child: child,
  );
}
