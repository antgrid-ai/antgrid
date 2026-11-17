import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/theme.dart';

/// The state a [CarbonStatusIcon] reports.
enum CarbonStatusKind { error, warning, success, info }

// The "!" of the warning glyph must read dark on Carbon's yellow in every
// theme, so it is not taken from a theme role that flips with brightness.
const Color _warningGlyph = Color(0xFF161616);

/// Carbon's filled status glyph: error, warning, success or information, in
/// the matching `support-*` colour.
///
/// Meaning must not rest on colour alone, so pass a [semanticLabel] wherever
/// the icon is the only carrier of the state; with none the icon is purely
/// decorative and excluded from semantics, for use beside text that already
/// says it. [CarbonNotification] draws its leading icon through this widget.
///
/// [color] and [innerColor] exist for surfaces that need a different accent
/// (the inverse notification) or an opaque inner mark. By default the warning
/// "!" is a fixed dark and the other kinds' inner marks stay transparent, so
/// the surface behind shows through.
class CarbonStatusIcon extends StatelessWidget {
  const CarbonStatusIcon(
    this.kind, {
    super.key,
    this.size = 16,
    this.semanticLabel,
    this.color,
    this.innerColor,
  });

  final CarbonStatusKind kind;
  final double size;

  /// Labels the icon as an image when non-null.
  final String? semanticLabel;

  /// Overrides the kind's `support-*` colour.
  final Color? color;

  /// Overrides the inner mark's fill.
  final Color? innerColor;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    final (icon, accent) = switch (kind) {
      CarbonStatusKind.error => (CarbonIcons.errorFilled, colors.supportError),
      CarbonStatusKind.warning => (
        CarbonIcons.warningAltFilled,
        colors.supportWarning,
      ),
      CarbonStatusKind.success => (
        CarbonIcons.checkmarkFilled,
        colors.supportSuccess,
      ),
      CarbonStatusKind.info => (
        CarbonIcons.informationFilled,
        colors.supportInfo,
      ),
    };
    return CarbonIcon(
      icon,
      size: size,
      color: color ?? accent,
      innerColor:
          innerColor ?? (kind == CarbonStatusKind.warning ? _warningGlyph : null),
      semanticLabel: semanticLabel,
    );
  }
}
