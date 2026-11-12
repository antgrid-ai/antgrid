import 'package:flutter/widgets.dart';

import '../foundations/colors.dart';
import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import 'tooltip.dart';

/// Semantic hue of a [CarbonTag]. The role carries category meaning only;
/// state such as selected or disabled is shown by other cues as well.
enum CarbonTagColor {
  red,
  magenta,
  purple,
  blue,
  cyan,
  teal,
  green,
  gray,
  coolGray,
  warmGray,

  /// Inverse fill for the strongest emphasis.
  highContrast,

  /// Transparent fill with an outline.
  outline,
}

/// Carbon tag heights; the pill grows with large text.
enum CarbonTagSize {
  small(18),
  medium(24),
  large(32);

  const CarbonTagSize(this.height);
  final double height;
}

/// A compact label for categorising or filtering.
///
/// Variants, chosen by which parameters are given:
/// * read-only: only [label];
/// * dismissible: [onDismissed] adds a separate remove target;
/// * selectable: [selected] with [onSelectedChanged] toggles on tap and adds a
///   check mark so selection is not color alone;
/// * operational: [onPressed] makes the whole tag a button.
///
/// Selection and removal are independent targets; neither triggers the other.
/// Interactive tags reserve a [CarbonThemeData.minTarget]-tall footprint in
/// layout (the pill is painted inside it) so neighbouring tags and actions
/// never overlap. Long labels truncate with an ellipsis, while semantics carry
/// the whole label.
class CarbonTag extends StatelessWidget {
  const CarbonTag({
    super.key,
    required this.label,
    this.color = CarbonTagColor.gray,
    this.size = CarbonTagSize.medium,
    this.icon,
    this.onDismissed,
    this.dismissLabel,
    this.selected,
    this.onSelectedChanged,
    this.onPressed,
    this.disabled = false,
    this.dismissFocusNode,
    this.focusNode,
  }) : assert(
         selected == null || onPressed == null,
         'A tag is either selectable or operational, not both.',
       );

  final String label;
  final CarbonTagColor color;
  final CarbonTagSize size;

  /// Leading glyph, normally a 16px [CarbonIcon].
  final Widget? icon;

  /// Adds the remove action; called when the remove target is activated.
  final VoidCallback? onDismissed;

  /// Overrides the localized remove-action name.
  final String? dismissLabel;

  /// Non-null makes the tag selectable; the host owns the value.
  final bool? selected;

  /// Requests the opposite selection. Null leaves a selectable tag inert.
  final ValueChanged<bool>? onSelectedChanged;

  /// Makes the whole tag a button.
  final VoidCallback? onPressed;

  /// Greys the tag and disables every action on it.
  final bool disabled;

  final FocusNode? dismissFocusNode;

  /// Focus node of the selectable or operational main target.
  final FocusNode? focusNode;

  bool get _selectable => selected != null;
  bool get _mainInteractive =>
      _selectable ? onSelectedChanged != null : onPressed != null;
  bool get _dismissible => onDismissed != null;

  bool _truncates(BuildContext context, TextStyle style, double available) {
    if (!available.isFinite) return false;
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width > available + 0.5;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final isSelected = selected == true;
    final interactive = _mainInteractive || _dismissible;
    final footprint = interactive
        ? (theme.minTarget > size.height ? theme.minTarget : size.height)
        : size.height;
    final extra = (footprint - size.height) / 2;

    final layerLevel = CarbonLayer.of(context);
    final operational = !_selectable && onPressed != null;
    final _TagPalette palette;
    if (disabled) {
      palette = _TagPalette(
        background: theme.layer(layerLevel),
        foreground: colors.textDisabled,
        hover: theme.layer(layerLevel),
        // Only selectable and operational tags are outlined; a read-only or
        // dismissible one is a plain fill.
        border: _selectable || operational ? colors.borderDisabled : null,
      );
    } else if (isSelected) {
      palette = _TagPalette(
        background: colors.layerSelectedInverse,
        foreground: colors.textInverse,
        // Carbon holds the selected fill on hover.
        hover: colors.layerSelectedInverse,
        border: null,
      );
    } else if (_selectable) {
      // Carbon's selectable tag is a core-token filter chip, not a coloured
      // category, so it reads as switchable.
      palette = _TagPalette(
        background: theme.layer(layerLevel),
        foreground: colors.textPrimary,
        hover: theme.layerHover(layerLevel),
        border: colors.borderInverse,
      );
    } else {
      palette = _palette(colors, color, bordered: operational);
    }

    final radius = BorderRadius.all(CarbonShape.pill);
    final style = theme.typography.label.copyWith(color: palette.foreground);
    final hasIcon = isSelected || icon != null;
    final large = size == CarbonTagSize.large;
    final padEnd = large ? CarbonSpacing.spacing04 : CarbonSpacing.spacing03;
    final padStart = hasIcon
        ? (large ? CarbonSpacing.spacing03 : CarbonSpacing.spacing02)
        : padEnd;

    Widget content({required bool trailingPad}) {
      return Padding(
        padding: EdgeInsetsDirectional.only(
          start: padStart,
          end: trailingPad ? padEnd : 0,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: size.height),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                CarbonIcon(
                  CarbonIcons.checkmark,
                  size: 16,
                  color: palette.foreground,
                ),
                const SizedBox(width: CarbonSpacing.spacing02),
              ] else if (icon != null) ...[
                IconTheme(
                  data: IconThemeData(color: palette.foreground, size: 16),
                  child: icon!,
                ),
                const SizedBox(width: CarbonSpacing.spacing02),
              ],
              Flexible(
                child: Text(
                  label,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget main;
    final mainBody = Padding(
      padding: EdgeInsets.symmetric(vertical: extra),
      child: ConstrainedBox(
        // Short labels would otherwise leave a target narrower than the floor.
        constraints: BoxConstraints(
          minWidth: _mainInteractive ? theme.minTarget : 0,
        ),
        child: content(trailingPad: !_dismissible),
      ),
    );
    if (_mainInteractive) {
      final VoidCallback? press = disabled
          ? null
          : (_selectable
                ? () => onSelectedChanged!(!isSelected)
                : onPressed);
      main = CarbonInteraction(
        onPressed: press,
        focusNode: focusNode,
        button: true,
        label: label,
        selected: _selectable ? isSelected : null,
        excludeChildSemantics: true,
        builder: (context, state, child) => Stack(
          children: [
            Positioned.fill(
              top: extra,
              bottom: extra,
              child: CarbonFocusRing(
                visible: state.focusVisible,
                onColor: true,
                borderRadius: radius,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    color: (state.hovered || state.pressed)
                        ? palette.hover
                        : const Color(0x00000000),
                  ),
                ),
              ),
            ),
            child!,
          ],
        ),
        child: mainBody,
      );
    } else {
      main = Semantics(
        container: true,
        label: label,
        selected: _selectable ? isSelected : null,
        child: ExcludeSemantics(child: mainBody),
      );
    }
    final fixedWidth =
        padStart +
        (_dismissible ? 0 : padEnd) +
        (hasIcon ? 16 + CarbonSpacing.spacing02 : 0);
    final mainTarget = main;
    main = LayoutBuilder(
      builder: (context, constraints) => CarbonTooltip(
        message: label,
        // The tag node already carries the full label as its name.
        excludeFromSemantics: true,
        enabled: _truncates(
          context,
          style,
          constraints.maxWidth - fixedWidth,
        ),
        child: mainTarget,
      ),
    );

    final loc = CarbonLocalizations.of(context);
    Widget? remove;
    if (_dismissible) {
      remove = CarbonInteraction(
        onPressed: disabled ? null : onDismissed,
        focusNode: dismissFocusNode,
        label: dismissLabel ?? loc.removeItem(label),
        excludeChildSemantics: true,
        builder: (context, state, _) => SizedBox(
          width: theme.minTarget,
          height: footprint,
          child: Center(
            child: CarbonFocusRing(
              visible: state.focusVisible,
              onColor: true,
              borderRadius: radius,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (state.hovered || state.pressed)
                      ? palette.hover
                      : const Color(0x00000000),
                ),
                child: SizedBox.square(
                  dimension: size.height,
                  child: Center(
                    child: CarbonIcon(
                      CarbonIcons.close,
                      size: 16,
                      color: palette.foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final pill = Positioned.fill(
      top: extra,
      bottom: extra,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.background,
          borderRadius: radius,
          border: palette.border == null
              ? null
              : Border.all(color: palette.border!),
        ),
      ),
    );

    return ConstrainedBox(
      // Carbon keeps a tag pill-shaped at 32 and truncates it at 208.
      constraints: const BoxConstraints(minWidth: 32, maxWidth: 208),
      child: Stack(
        alignment: AlignmentDirectional.center,
        children: [
          pill,
          // The row sizes the stack; the pill fill is painted behind it.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [Flexible(child: main), ?remove],
          ),
        ],
      ),
    );
  }
}

class _TagPalette {
  const _TagPalette({
    required this.background,
    required this.foreground,
    required this.hover,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color hover;
  final Color? border;
}

// Only operational tags carry their role's border; read-only and dismissible
// tags are borderless fills.
_TagPalette _palette(
  CarbonColors c,
  CarbonTagColor color, {
  required bool bordered,
}) {
  _TagPalette from(CarbonTagColors t) => _TagPalette(
    background: t.background,
    foreground: t.foreground,
    hover: t.hover,
    border: bordered ? t.border : null,
  );
  return switch (color) {
    CarbonTagColor.red => from(c.tagRed),
    CarbonTagColor.magenta => from(c.tagMagenta),
    CarbonTagColor.purple => from(c.tagPurple),
    CarbonTagColor.blue => from(c.tagBlue),
    CarbonTagColor.cyan => from(c.tagCyan),
    CarbonTagColor.teal => from(c.tagTeal),
    CarbonTagColor.green => from(c.tagGreen),
    CarbonTagColor.gray => from(c.tagGray),
    CarbonTagColor.coolGray => from(c.tagCoolGray),
    CarbonTagColor.warmGray => from(c.tagWarmGray),
    CarbonTagColor.highContrast => _TagPalette(
      background: c.backgroundInverse,
      foreground: c.textInverse,
      hover: c.backgroundInverseHover,
      border: null,
    ),
    CarbonTagColor.outline => _TagPalette(
      background: const Color(0x00000000),
      foreground: c.textPrimary,
      hover: c.layerHover01,
      border: c.borderInverse,
    ),
  };
}
