import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/interaction.dart';

/// Text size of a [CarbonLink].
enum CarbonLinkSize {
  /// Carbon `helper-text-01`.
  small,

  /// Carbon `body-compact-01`.
  medium,

  /// Carbon `body-compact-02`.
  large,
}

/// Carbon's standalone link: a text action that navigates.
///
/// * `link-primary` text; hover turns `link-primary-hover` and underlines;
///   pressed shows `text-primary` underlined; keyboard focus draws a 1px
///   `focus` outline and underlines.
/// * [onPressed] null disables the link: `text-disabled`, no underline (unless
///   [inline]) and no hover, press or focus.
/// * [inline] links sit in running text and are always underlined, as Carbon
///   does so they are not told apart by colour alone.
/// * [icon] follows the label in reading order, [CarbonSpacing.spacing03]
///   away, and takes the label's colour through [IconTheme].
/// * Touch density gives the link a [CarbonThemeData.touchTarget]-tall hit
///   area; the text itself does not move.
class CarbonLink extends StatelessWidget {
  const CarbonLink({
    super.key,
    required this.label,
    this.onPressed,
    this.inline = false,
    this.icon,
    this.size = CarbonLinkSize.medium,
    this.semanticLabel,
    this.focusNode,
  });

  final String label;

  /// Activates the link. Null disables it.
  final VoidCallback? onPressed;

  final bool inline;

  /// Trailing glyph, placed after the label in reading direction.
  final Widget? icon;

  final CarbonLinkSize size;

  /// Announced instead of [label].
  final String? semanticLabel;

  final FocusNode? focusNode;

  TextStyle _style(CarbonThemeData theme) {
    final type = theme.typography;
    return switch (size) {
      CarbonLinkSize.small => type.helper,
      CarbonLinkSize.medium => type.control,
      // Touch density's control style is already body-compact-02.
      CarbonLinkSize.large =>
        theme.isTouch
            ? type.control
            : type.control.copyWith(
                fontSize: 16,
                height: 22 / 16,
                letterSpacing: 0,
              ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final style = _style(theme);
    return CarbonInteraction(
      onPressed: onPressed,
      focusNode: focusNode,
      button: false,
      link: true,
      label: semanticLabel ?? label,
      excludeChildSemantics: true,
      builder: (context, state, _) {
        final underline =
            inline || state.hovered || state.pressed || state.focusVisible;
        final color = !state.enabled
            ? colors.textDisabled
            : state.pressed
            ? colors.textPrimary
            : state.hovered
            ? colors.linkPrimaryHover
            : colors.linkPrimary;
        Widget content = Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(
            color: color,
            decoration: underline ? TextDecoration.underline : null,
            decorationColor: color,
          ),
        );
        if (icon != null) {
          content = Row(
            mainAxisSize: MainAxisSize.min,
            spacing: CarbonSpacing.spacing03,
            children: [
              Flexible(child: content),
              IconTheme.merge(
                data: IconThemeData(color: color),
                child: icon!,
              ),
            ],
          );
        }
        final text = DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: state.focusVisible
                ? Border.all(color: colors.focus)
                : null,
          ),
          child: content,
        );
        if (!theme.isTouch) return text;
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: theme.touchTarget),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            // Without it the link stretches to fill a bounded column.
            heightFactor: 1,
            child: text,
          ),
        );
      },
    );
  }
}
