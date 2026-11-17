import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'theme.dart';

/// Named Carbon type roles, resolved for one density.
///
/// Compact uses Carbon's productive set; touch raises control and body text to
/// 16px and supporting text to 14px within the same hierarchy. Every role sets
/// family, size, weight, line height and tracking explicitly so text never
/// inherits an application default by accident.
@immutable
class CarbonTypography {
  const CarbonTypography({
    required this.label,
    required this.helper,
    required this.control,
    required this.body,
    required this.heading,
    required this.headingLarge,
    required this.title,
    required this.code,
  });

  /// Field labels, tag text, tab text in compact mode.
  final TextStyle label;

  /// Helper and validation text under a field.
  final TextStyle helper;

  /// Text inside single-line controls: buttons, inputs, menu items, rows.
  final TextStyle control;

  /// Running text: modal and notification bodies.
  final TextStyle body;

  /// Section and row headings.
  final TextStyle heading;

  /// Modal titles and larger section headings.
  final TextStyle headingLarge;

  /// Page-level headings.
  final TextStyle title;

  /// Code and data: identifiers, paths, ports. Never chrome.
  final TextStyle code;

  /// The package-bundled sans family. Pass [package] alongside it when building
  /// a [TextStyle] by hand.
  static const String sansFamily = 'IBM Plex Sans';

  /// The package-bundled mono family.
  static const String monoFamily = 'IBM Plex Mono';

  /// The asset package that owns [sansFamily] and [monoFamily].
  static const String package = 'carbon_flutter';

  /// Carbon defaults for [density], with the bundled IBM Plex families.
  ///
  /// [sansFamily]/[monoFamily] substitute other families; set [fontPackage] to
  /// the package that bundles them, or null for an application-level family.
  /// Substitutes change metrics, so validate them in the gallery.
  factory CarbonTypography.forDensity(
    CarbonDensity density, {
    String sansFamily = CarbonTypography.sansFamily,
    String monoFamily = CarbonTypography.monoFamily,
    String? fontPackage = CarbonTypography.package,
    List<String> fontFamilyFallback = const <String>[],
  }) {
    TextStyle sans(double size, double lineHeight, FontWeight weight,
            double tracking) =>
        TextStyle(
          inherit: false,
          fontFamily: sansFamily,
          package: fontPackage,
          fontFamilyFallback: fontFamilyFallback,
          fontSize: size,
          height: lineHeight / size,
          fontWeight: weight,
          letterSpacing: tracking,
          leadingDistribution: TextLeadingDistribution.even,
          textBaseline: TextBaseline.alphabetic,
        );
    TextStyle mono(double size, double lineHeight) =>
        sans(size, lineHeight, FontWeight.w400, 0.32).copyWith(
          fontFamily: monoFamily,
          package: fontPackage,
        );
    const regular = FontWeight.w400;
    const semibold = FontWeight.w600;
    return switch (density) {
      // label-01, helper-text-01, body-compact-01, body-01,
      // heading-compact-01, heading-compact-02, heading-03, code-01.
      CarbonDensity.compact => CarbonTypography(
        label: sans(12, 16, regular, 0.32),
        helper: sans(12, 16, regular, 0.32),
        control: sans(14, 18, regular, 0.16),
        body: sans(14, 20, regular, 0.16),
        heading: sans(14, 18, semibold, 0.16),
        headingLarge: sans(16, 22, semibold, 0),
        title: sans(20, 28, regular, 0),
        code: mono(12, 16),
      ),
      // label-02, helper-text-02, body-compact-02, body-02,
      // heading-compact-02, heading-03, heading-04, code-02.
      CarbonDensity.touch => CarbonTypography(
        label: sans(14, 18, regular, 0.16),
        helper: sans(14, 18, regular, 0.16),
        control: sans(16, 22, regular, 0),
        body: sans(16, 24, regular, 0),
        heading: sans(16, 22, semibold, 0),
        headingLarge: sans(20, 28, regular, 0),
        title: sans(28, 36, regular, 0),
        code: mono(14, 20),
      ),
    };
  }

  CarbonTypography copyWith({
    TextStyle? label,
    TextStyle? helper,
    TextStyle? control,
    TextStyle? body,
    TextStyle? heading,
    TextStyle? headingLarge,
    TextStyle? title,
    TextStyle? code,
  }) {
    return CarbonTypography(
      label: label ?? this.label,
      helper: helper ?? this.helper,
      control: control ?? this.control,
      body: body ?? this.body,
      heading: heading ?? this.heading,
      headingLarge: headingLarge ?? this.headingLarge,
      title: title ?? this.title,
      code: code ?? this.code,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CarbonTypography &&
      other.label == label &&
      other.helper == helper &&
      other.control == control &&
      other.body == body &&
      other.heading == heading &&
      other.headingLarge == headingLarge &&
      other.title == title &&
      other.code == code;

  @override
  int get hashCode => Object.hash(
    label,
    helper,
    control,
    body,
    heading,
    headingLarge,
    title,
    code,
  );
}
