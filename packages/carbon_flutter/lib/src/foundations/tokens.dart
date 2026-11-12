import 'package:flutter/widgets.dart';

/// Carbon's spacing scale (`$spacing-01` … `$spacing-13`), in logical pixels.
///
/// Components use these; consumer screens should too, so related controls
/// align without one-off insets.
abstract final class CarbonSpacing {
  static const double spacing01 = 2;
  static const double spacing02 = 4;
  static const double spacing03 = 8;
  static const double spacing04 = 12;
  static const double spacing05 = 16;
  static const double spacing06 = 24;
  static const double spacing07 = 32;
  static const double spacing08 = 40;
  static const double spacing09 = 48;
  static const double spacing10 = 64;
  static const double spacing11 = 80;
  static const double spacing12 = 96;
  static const double spacing13 = 160;
}

/// Carbon component sizes (`$size-*`), the vocabulary behind
/// [CarbonThemeData.controlHeight].
abstract final class CarbonSizes {
  static const double xs = 24;
  static const double sm = 32;
  static const double md = 40;
  static const double lg = 48;
  static const double xl = 64;
  static const double xxl = 80;
}

/// Stroke widths. Carbon separates with 1px rules and marks keyboard focus
/// with a 2px inset outline.
abstract final class CarbonBorders {
  static const double hairline = 1;
  static const double focus = 2;

  /// The selected indicator on tabs and the bottom rule of a focused field.
  static const double indicator = 2;

  /// The bottom rule of a selected contained tab.
  static const double selectedTab = 3;
}

/// Corner treatment. Carbon controls are square; the exceptions are named so
/// no component invents its own radius.
abstract final class CarbonShape {
  static const Radius none = Radius.zero;

  /// Tooltips and toggletips.
  static const Radius tooltip = Radius.circular(2);

  /// Pill-shaped tags.
  static const Radius pill = Radius.circular(24);

  /// The toggle track and its handle.
  static const Radius toggle = Radius.circular(12);
}

/// Carbon motion tokens (`@carbon/motion`).
abstract final class CarbonMotion {
  static const Duration fast01 = Duration(milliseconds: 70);
  static const Duration fast02 = Duration(milliseconds: 110);
  static const Duration moderate01 = Duration(milliseconds: 150);
  static const Duration moderate02 = Duration(milliseconds: 240);
  static const Duration slow01 = Duration(milliseconds: 400);
  static const Duration slow02 = Duration(milliseconds: 700);

  /// Productive standard easing: elements moving within the view.
  static const Curve standard = Cubic(0.2, 0, 0.38, 0.9);

  /// Productive entrance easing: elements appearing.
  static const Curve entrance = Cubic(0, 0, 0.38, 0.9);

  /// Productive exit easing: elements leaving.
  static const Curve exit = Cubic(0.2, 0, 1, 0.9);

  /// Whether the platform asks for reduced motion. Components skip decorative
  /// transitions and switch repeating indicators to a static presentation.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or zero under reduced motion.
  static Duration resolve(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}
