import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';

/// A whole-surface action: a tile filled with the current layer that darkens on
/// hover and press, with Carbon's trailing arrow in its bottom end corner
/// (always drawn; see C-tile-arrow in doc/deviations.md).
///
/// Carbon's `ClickableTile` is an anchor that navigates; this one runs
/// [onPressed], so the host decides whether that navigates. A null [onPressed]
/// disables the tile: it keeps its fill, dims text and arrow, takes no focus
/// and is announced as a disabled button.
///
/// The fill follows the enclosing [CarbonLayer], so a tile placed on a layered
/// surface steps up a layer as Carbon's `light` tile and layer context do.
/// [child] is free-form and non-interactive; it carries the tile's default
/// body text style. Without [semanticLabel] its text merges into the tile's
/// accessible name; with one, the label replaces it.
class CarbonClickableTile extends StatelessWidget {
  const CarbonClickableTile({
    super.key,
    required this.child,
    this.onPressed,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget child;

  /// Null disables the tile.
  final VoidCallback? onPressed;

  /// Overrides the name read from [child].
  final String? semanticLabel;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Carbon's tile is never shorter than 40; touch density lifts it to the
  /// theme's touch target.
  static const double _minHeight = 40;

  /// Carbon's tile arrow is 20 px and sits 12 px in from the bottom end
  /// corner, whatever the density.
  static const double _arrowSize = 20;
  static const double _arrowInset = 12;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final level = CarbonLayer.of(context);
    return CarbonInteraction(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      label: semanticLabel,
      excludeChildSemantics: semanticLabel != null,
      builder: (context, state, _) {
        final disabled = !state.enabled;
        final fill = state.pressed
            ? theme.layerActive(level)
            : state.hovered
            ? theme.layerHover(level)
            : theme.layer(level);
        return CarbonFocusRing(
          visible: state.focusVisible,
          child: ColoredBox(
            color: fill,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(_minHeight, theme.minTarget),
              ),
              child: Stack(
                children: <Widget>[
                  Padding(
                    // Carbon lets the arrow overlap the content; reserving its
                    // corner keeps wrapped text from running under it.
                    padding: EdgeInsetsDirectional.only(
                      start: CarbonSpacing.spacing05,
                      top: CarbonSpacing.spacing05,
                      bottom: CarbonSpacing.spacing05,
                      end: _arrowInset + _arrowSize + CarbonSpacing.spacing03,
                    ),
                    child: DefaultTextStyle(
                      style: theme.typography.body.copyWith(
                        color: disabled
                            ? colors.textDisabled
                            : colors.textPrimary,
                      ),
                      child: child,
                    ),
                  ),
                  PositionedDirectional(
                    end: _arrowInset,
                    bottom: _arrowInset,
                    child: ExcludeSemantics(
                      child: CarbonIcon(
                        CarbonIcons.arrowRight,
                        size: _arrowSize,
                        color: disabled
                            ? colors.iconDisabled
                            : colors.iconInteractive,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
