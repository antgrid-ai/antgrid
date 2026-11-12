import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

// A ghost menu button's text-bearing chrome: Carbon pads it by spacing05 on
// both sides (density does not change that), then a spacing05 gap before the
// chevron box. The leading glyph adds its box plus a spacing03 gap.
const double _chromePadX = CarbonSpacing.spacing05;
const double _chevronGap = CarbonSpacing.spacing05;
const double _leadingGap = CarbonSpacing.spacing03;

/// The label room that still reads as a name rather than a clipped letter.
const double _labelStub = CarbonSpacing.spacing08;

/// The longest label a picker draws when its slot is unbounded, e.g. inside a
/// horizontal scroller.
const double _labelCap = CarbonSpacing.spacing13;

/// The width at which a picker has shed its label and shows only its glyph.
double contextPickerGlyphWidth(CarbonThemeData t) => t.minTarget;

/// The narrowest a picker with a leading glyph stays a labelled trigger; below
/// it the picker sheds to [contextPickerGlyphWidth].
double contextPickerFullMinWidth(CarbonThemeData t) =>
    _fullWidth(t, hasIcon: true, label: _labelStub);

double _fullWidth(
  CarbonThemeData t, {
  required bool hasIcon,
  required double label,
}) =>
    2 * _chromePadX +
    (hasIcon ? t.iconSize + _leadingGap : 0) +
    label +
    _chevronGap +
    t.iconSize;

/// One value of the new-session context row (environment, project, branch,
/// agent): a ghost menu button showing the current value, which opens above
/// the row so it never covers the prompt.
///
/// [icon] null means no leading glyph and no shedding (the agent trigger).
/// Narrow slots degrade in steps: full trigger, glyph-only overflow menu,
/// scaled-down glyph, nothing.
class ContextPicker extends StatelessWidget {
  const ContextPicker({
    super.key,
    this.icon,
    required this.label,
    required this.field,
    required this.entries,
    this.enabled = true,
    this.attention = false,
    this.onOpenChanged,
    this.shedToIcon = true,
  });

  final CarbonIcons? icon;

  /// The current value, drawn on the trigger.
  final String label;

  /// What the value is for ("Environment", "Project"); with [label] it names
  /// the trigger for assistive technology.
  final String field;
  final List<CarbonMenuEntry> entries;
  final bool enabled;

  /// Tints the leading glyph to draw the eye to a picker that needs a choice.
  final bool attention;
  final ValueChanged<bool>? onOpenChanged;
  final bool shedToIcon;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final name = '$field: $label';
    final icon = this.icon;
    final glyph = icon == null
        ? null
        : CarbonIcon(icon, color: attention ? t.colors.iconInteractive : null);

    Widget full() => CarbonMenuButton(
      label: label,
      kind: CarbonButtonKind.ghost,
      entries: entries,
      enabled: enabled,
      leading: glyph,
      maxLines: 1,
      preferAbove: true,
      semanticLabel: field,
      triggerSemanticLabel: name,
      onOpenChanged: onOpenChanged,
    );

    Widget glyphOnly() => CarbonOverflowMenu(
      entries: entries,
      enabled: enabled,
      icon: glyph,
      preferAbove: true,
      semanticLabel: name,
      menuLabel: field,
      onOpenChanged: onOpenChanged,
    );

    Widget start(Widget child) => Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: child,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width <= 0) return const SizedBox.shrink();
        if (!width.isFinite) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: _fullWidth(t, hasIcon: icon != null, label: _labelCap),
            ),
            child: full(),
          );
        }
        final sheds = icon != null && shedToIcon;
        // A picker that cannot shed keeps its label, scaled down from the
        // narrowest trigger that still reads, rather than overflowing.
        final floor = _fullWidth(t, hasIcon: icon != null, label: _labelStub);
        if (!sheds && width < floor) {
          return SizedBox(
            width: width,
            height: t.controlHeight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(width: floor, child: full()),
            ),
          );
        }
        if (width < t.minTarget) {
          return SizedBox(
            width: width,
            height: t.controlHeight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: glyphOnly(),
            ),
          );
        }
        if (sheds && width < contextPickerFullMinWidth(t)) {
          return start(glyphOnly());
        }
        return start(full());
      },
    );
  }
}
