import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/interaction.dart';

/// One step in a [CarbonBreadcrumb].
class CarbonBreadcrumbItem {
  const CarbonBreadcrumbItem({required this.label, this.onPressed});

  final String label;

  /// Navigates to this step. Null marks the current page, which Carbon shows
  /// as plain `text-primary` rather than a link.
  final VoidCallback? onPressed;
}

/// Carbon's breadcrumb: the path from a parent page to the current one, shown
/// above a page title.
///
/// * Links use `body-compact-01` in `link-primary`, underline and turn
///   `link-primary-hover` on hover, show `text-primary` while pressed, and
///   draw a 1px `focus` outline with an underline under keyboard focus.
/// * Each step is followed by a `/` separator in `text-primary`, including the
///   last unless [trailingSlash] is false. Carbon's page-header pattern keeps
///   the trailing slash when the current page's title is shown below.
/// * Touch density gives each link a [CarbonThemeData.touchTarget]-tall hit
///   area; the text itself does not move.
/// * Steps wrap onto further lines when they do not fit.
class CarbonBreadcrumb extends StatelessWidget {
  const CarbonBreadcrumb({
    super.key,
    required this.items,
    this.trailingSlash = true,
  });

  final List<CarbonBreadcrumbItem> items;
  final bool trailingSlash;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final style = theme.typography.control;
    final slash = ExcludeSemantics(
      child: Text('/', style: style.copyWith(color: colors.textPrimary)),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: CarbonSpacing.spacing03,
      children: [
        for (var i = 0; i < items.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: CarbonSpacing.spacing03,
            children: [
              Flexible(child: _BreadcrumbLink(item: items[i])),
              if (trailingSlash || i < items.length - 1) slash,
            ],
          ),
      ],
    );
  }
}

class _BreadcrumbLink extends StatelessWidget {
  const _BreadcrumbLink({required this.item});

  final CarbonBreadcrumbItem item;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final style = theme.typography.control;
    final onPressed = item.onPressed;
    if (onPressed == null) {
      return Text(
        item.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(color: colors.textPrimary),
      );
    }
    return CarbonInteraction(
      onPressed: onPressed,
      label: item.label,
      excludeChildSemantics: true,
      builder: (context, state, _) {
        final underline = state.hovered || state.pressed || state.focusVisible;
        final color = state.pressed
            ? colors.textPrimary
            : state.hovered
            ? colors.linkPrimaryHover
            : colors.linkPrimary;
        final text = DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: state.focusVisible
                ? Border.all(color: colors.focus)
                : null,
          ),
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(
              color: color,
              decoration: underline ? TextDecoration.underline : null,
              decorationColor: color,
            ),
          ),
        );
        if (!theme.isTouch) return text;
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: theme.touchTarget),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: text,
          ),
        );
      },
    );
  }
}
