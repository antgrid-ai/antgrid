import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import 'drawer_metrics.dart';

/// A full-width action row under the drawer's list, headed by a hairline: the
/// account footer's trigger and the update row are both one of these.
///
/// The row is one tab stop. [trailing] sits inside the rail inset, so a glyph
/// centred in a [drawerRailCell] there lands on the same line as every row's
/// trailing glyph above it.
class DrawerChromeRow extends StatelessWidget {
  const DrawerChromeRow({
    super.key,
    required this.icon,
    required this.label,
    this.trailing,
    this.onPressed,
    this.focusNode,
    this.iconColor,
    this.semanticLabel,
    this.expanded,
  });

  final CarbonIcons icon;
  final String label;
  final Widget? trailing;

  /// Null makes the row inert: it keeps its look but ignores taps and focus.
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  /// Defaults to `iconSecondary`.
  final Color? iconColor;

  /// What assistive technology hears, for a row whose [trailing] carries part
  /// of the meaning. Defaults to [label].
  final String? semanticLabel;

  /// Set for a row that opens a popup, so its open state is announced.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final c = t.colors;
    final minHeight = t.isTouch ? t.minTarget : CarbonSizes.md;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.borderSubtle00)),
      ),
      child: CarbonInteraction(
        focusNode: focusNode,
        onPressed: onPressed,
        label: semanticLabel ?? label,
        expanded: expanded,
        excludeChildSemantics: true,
        builder: (context, state, _) => CarbonFocusRing(
          visible: state.focusVisible,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: state.pressed
                  ? c.backgroundActive
                  : state.hovered
                  ? c.backgroundHover
                  : null,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: CarbonSpacing.spacing05,
                  end: kDrawerRailInset,
                ),
                child: Row(
                  children: [
                    CarbonIcon(icon, color: iconColor ?? c.iconSecondary),
                    const SizedBox(width: CarbonSpacing.spacing03),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.typography.control.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
