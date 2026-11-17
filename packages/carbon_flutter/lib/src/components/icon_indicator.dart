import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import 'tooltip.dart';

/// The statuses of Carbon's icon indicator, each a fixed glyph and colour.
enum CarbonIconIndicatorKind {
  failed,
  cautionMajor,
  cautionMinor,
  undefined,
  succeeded,
  normal,
  inProgress,
  incomplete,
  notStarted,
  pending,
  unknown,
  informative,
}

enum _Status { red, orange, yellow, purple, green, blue, gray }

// The `status-*` component tokens of @carbon/themes. White and Gray 10 share
// one set and Gray 90 and Gray 100 the other, so brightness picks the column.
const Map<_Status, (Color, Color)> _statusColors = {
  _Status.red: (Color(0xFFDA1E28), Color(0xFFFA4D56)),
  _Status.orange: (Color(0xFFFF832B), Color(0xFFFF832B)),
  _Status.yellow: (Color(0xFFF1C21B), Color(0xFFF1C21B)),
  _Status.purple: (Color(0xFF8A3FFC), Color(0xFFA56EFF)),
  _Status.green: (Color(0xFF24A148), Color(0xFF42BE65)),
  _Status.blue: (Color(0xFF0043CE), Color(0xFF4589FF)),
  _Status.gray: (Color(0xFF6F6F6F), Color(0xFF8D8D8D)),
};

// The caution marks are `$black` on the orange and yellow in every theme.
const Color _cautionMark = Color(0xFF000000);

(CarbonIcons, _Status) _glyph(CarbonIconIndicatorKind kind) => switch (kind) {
  CarbonIconIndicatorKind.failed => (CarbonIcons.errorFilled, _Status.red),
  CarbonIconIndicatorKind.cautionMajor => (
    CarbonIcons.warningAltInvertedFilled,
    _Status.orange,
  ),
  CarbonIconIndicatorKind.cautionMinor => (
    CarbonIcons.warningAltFilled,
    _Status.yellow,
  ),
  CarbonIconIndicatorKind.undefined => (
    CarbonIcons.undefinedFilled,
    _Status.purple,
  ),
  CarbonIconIndicatorKind.succeeded => (
    CarbonIcons.checkmarkFilled,
    _Status.green,
  ),
  CarbonIconIndicatorKind.normal => (
    CarbonIcons.checkmarkOutline,
    _Status.blue,
  ),
  CarbonIconIndicatorKind.inProgress => (CarbonIcons.inProgress, _Status.blue),
  CarbonIconIndicatorKind.incomplete => (CarbonIcons.incomplete, _Status.blue),
  CarbonIconIndicatorKind.notStarted => (CarbonIcons.circleDash, _Status.gray),
  CarbonIconIndicatorKind.pending => (CarbonIcons.pendingFilled, _Status.gray),
  CarbonIconIndicatorKind.unknown => (CarbonIcons.unknownFilled, _Status.gray),
  CarbonIconIndicatorKind.informative => (
    CarbonIcons.warningSquareFilled,
    _Status.blue,
  ),
};

/// Carbon's icon indicator: a status glyph in its status colour beside a
/// label in `text-secondary`.
///
/// Every kind draws at the same size, so a column of mixed statuses lines up.
/// The size follows density: 16 px with `body-compact-01` text when compact,
/// 20 px with the larger control text under touch, matching Carbon's two
/// sizes. [compact] drops the visible label for a tooltip and keeps it as the
/// accessible name.
class CarbonIconIndicator extends StatelessWidget {
  const CarbonIconIndicator({
    super.key,
    required this.kind,
    required this.label,
    this.compact = false,
  });

  final CarbonIconIndicatorKind kind;

  /// Names the status, visibly or, when [compact], as the tooltip and
  /// accessible name.
  final String label;

  /// Shows only the glyph, with [label] in a tooltip.
  final bool compact;

  /// The status colour of [kind] in [theme].
  static Color colorOf(CarbonThemeData theme, CarbonIconIndicatorKind kind) {
    final pair = _statusColors[_glyph(kind).$2]!;
    return theme.brightness == Brightness.dark ? pair.$2 : pair.$1;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final (icon, _) = _glyph(kind);
    final caution =
        kind == CarbonIconIndicatorKind.cautionMajor ||
        kind == CarbonIconIndicatorKind.cautionMinor;
    final glyph = CarbonIcon(
      icon,
      size: theme.iconSize,
      color: colorOf(theme, kind),
      innerColor: caution ? _cautionMark : null,
    );
    if (compact) {
      return CarbonTooltip(
        message: label,
        child: Semantics(
          label: label,
          image: true,
          excludeSemantics: true,
          child: glyph,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: CarbonSpacing.spacing03,
      children: [
        ExcludeSemantics(child: glyph),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.typography.control.copyWith(
              color: theme.colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
