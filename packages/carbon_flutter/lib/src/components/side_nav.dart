import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import '../primitives/revealed_actions.dart';

/// How a side nav item lays out its [CarbonSideNavLink.trailing] marks against
/// its [CarbonSideNavLink.actions].
enum CarbonSideNavActions {
  /// Trailing marks and actions share one end slot, sized to the wider of the
  /// two. The marks show at rest; the actions replace them while the pointer
  /// is over the item, focus is inside it, or the host holds
  /// [CarbonSideNavLink.keepActionsRevealed]. Marks stay in semantics while
  /// covered, so they must not be focusable. Under touch density the actions
  /// are always shown and the marks sit inboard of them, as in [reserved].
  swap,

  /// The marks always show, and the actions get a slot of their own that is
  /// revealed the way a contained list row reveals its actions.
  reserved,
}

/// Where a [CarbonSideNavMenu] shows its disclosure chevron.
enum CarbonSideNavChevron {
  /// At the end of the item, rotating half a turn when open (upstream).
  end,

  /// In place of the leading icon, and only while a pointer is over the item:
  /// never on touch and never for focus alone (deviation CSN-chevron).
  swapsIcon,

  /// Right after the title, pointing toward the end when closed and down when
  /// open, so a heading-like menu reads as a disclosure next to its name and
  /// leaves the trailing slot to status marks (deviation CSN-chevron-inline).
  afterLabel,
}

/// What a side nav's items read from their surroundings: how deep they nest
/// and how they are inset. [CarbonSideNav] provides the root scope and
/// [CarbonSideNavMenu] provides one level deeper for its children.
class CarbonSideNavScope extends InheritedWidget {
  const CarbonSideNavScope({
    super.key,
    this.depth = 0,
    this.inset = CarbonSpacing.spacing05,
    this.endInset = CarbonSpacing.spacing05,
    this.nestStep,
    required super.child,
  });

  /// 0 for top-level items.
  final int depth;

  /// The start padding of a top-level item.
  final double inset;

  /// The trailing padding of every item.
  final double endInset;

  /// How far each nesting level moves an item's start. Null means the leading
  /// icon slot plus its gap, so a nested item's slot sits under its parent's
  /// title (deviation CSN-indent).
  final double? nestStep;

  static const CarbonSideNavScope _fallback = CarbonSideNavScope(
    child: SizedBox.shrink(),
  );

  /// The nearest scope, or the upstream defaults at depth 0.
  static CarbonSideNavScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CarbonSideNavScope>() ??
      _fallback;

  static int depthOf(BuildContext context) => of(context).depth;

  /// [child] under a scope one level deeper than the nearest one, for a host
  /// that renders a menu's children as siblings of its header instead of
  /// passing them as [CarbonSideNavMenu.children].
  static Widget nested({required BuildContext context, required Widget child}) {
    final scope = of(context);
    return CarbonSideNavScope(
      depth: scope.depth + 1,
      inset: scope.inset,
      endInset: scope.endInset,
      nestStep: scope.nestStep,
      child: child,
    );
  }

  /// [nestStep], or its default for [theme].
  double stepFor(CarbonThemeData theme) =>
      nestStep ?? theme.iconSize + CarbonSpacing.spacing03;

  @override
  bool updateShouldNotify(CarbonSideNavScope old) =>
      old.depth != depth ||
      old.inset != inset ||
      old.endInset != endInset ||
      old.nestStep != nestStep;
}

/// Carbon's UI Shell left panel: the `background` surface that holds the
/// primary navigation, announced as a navigation landmark.
///
/// Fill it with [CarbonSideNavLink], [CarbonSideNavMenu] and
/// [CarbonSideNavDivider]; [child] is otherwise free-form, so the host keeps
/// its own layout. [inset] and [endInset] move the items' edges (upstream is
/// 16 on both), which lets a host line its trailing controls up with a rail.
///
/// [endBorder] draws a 1px rule on the end edge. Upstream has none; the panel
/// is a pane beside other panes of near-`background` color (deviation
/// CSN-edge).
class CarbonSideNav extends StatelessWidget {
  const CarbonSideNav({
    super.key,
    required this.child,
    this.semanticLabel,
    this.width,
    this.endBorder = false,
    this.inset,
    this.endInset,
    this.nestStep,
  });

  final Widget child;

  /// The landmark's name; defaults to [CarbonLocalizations.sideNavigation].
  final String? semanticLabel;

  /// Null fills the parent.
  final double? width;
  final bool endBorder;
  final double? inset;
  final double? endInset;
  final double? nestStep;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final label =
        semanticLabel ?? CarbonLocalizations.of(context).sideNavigation;
    return Semantics(
      role: SemanticsRole.navigation,
      container: true,
      explicitChildNodes: true,
      label: label,
      child: SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colors.background,
            border: endBorder
                ? BorderDirectional(
                    end: BorderSide(
                      color: theme.borderSubtle(0),
                      width: CarbonBorders.hairline,
                    ),
                  )
                : null,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              end: endBorder ? CarbonBorders.hairline : 0,
            ),
            child: CarbonSideNavScope(
              inset: inset ?? CarbonSpacing.spacing05,
              endInset: endInset ?? CarbonSpacing.spacing05,
              nestStep: nestStep,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A 1px `borderSubtle` rule between groups of items.
class CarbonSideNavDivider extends StatelessWidget {
  const CarbonSideNavDivider({super.key, this.inset = true});

  /// Keeps the rule off the panel's edges; false runs it edge to edge.
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        vertical: CarbonSpacing.spacing03,
        horizontal: inset ? CarbonSpacing.spacing05 : 0,
      ),
      child: SizedBox(
        width: double.infinity,
        height: CarbonBorders.hairline,
        child: ColoredBox(color: theme.borderSubtle(0)),
      ),
    );
  }
}

/// A navigation item: an optional icon, a label, and the current-page state.
///
/// At depth 0 the label is `heading`; nested items (inside a
/// [CarbonSideNavMenu]) use `control`. Labels rest in `textSecondary`, take
/// `backgroundHover` and `textPrimary` under the pointer, and the current item
/// is `backgroundSelected` with a 3px `borderInteractive` start bar and a 600
/// weight at every depth. Flutter has no current-page flag, so the current item
/// announces as selected (deviation CSN-current).
///
/// The item is at least 32 (48 when [large]) compact or
/// [CarbonThemeData.minTarget] touch tall. The icon gap is 8, not upstream's
/// 24, which is too wide for a narrow panel (deviation CSN-icon-gap).
///
/// [trailing] holds non-interactive status marks. [actions] holds controls
/// (typically `CarbonButton.iconOnly`) that sit beside the item's own target,
/// so activating one never activates the item and keyboard focus visits the
/// item first, then each action; hidden actions stay focusable (deviation
/// CSN-actions). [actionsMode] picks how they share space with [trailing].
class CarbonSideNavLink extends StatelessWidget {
  const CarbonSideNavLink({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.current = false,
    this.onPressed,
    this.onLongPress,
    this.cancelOnLongPress = false,
    this.onDoublePressed,
    this.content,
    this.trailing = const <Widget>[],
    this.actions = const <Widget>[],
    this.actionsMode = CarbonSideNavActions.swap,
    this.keepActionsRevealed = false,
    this.large = false,
    this.disabled = false,
    this.focusNode,
    this.onFocusChange,
    this.onHoverChange,
  }) : assert(
         icon == null || leading == null,
         'Pass an icon or a leading widget, not both.',
       );

  /// The item's accessible name, and its text unless [content] replaces it.
  final String label;

  final CarbonIcons? icon;

  /// A widget for the leading slot instead of an [icon] (a status dot, a
  /// mark). The slot is the theme's icon size square; the widget is centred.
  final Widget? leading;

  final bool current;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// See [CarbonInteraction.cancelOnLongPress].
  final bool cancelOnLongPress;

  /// See [CarbonInteraction.onDoublePressed].
  final VoidCallback? onDoublePressed;

  /// Free-form, non-interactive content shown in place of the label text.
  /// [label] stays the accessible name; the content is hidden from semantics.
  final Widget? content;

  final List<Widget> trailing;
  final List<Widget> actions;
  final CarbonSideNavActions actionsMode;

  /// Holds the actions visible while the host has something open on them (a
  /// menu or a dialog), so they do not vanish when the pointer leaves.
  final bool keepActionsRevealed;

  /// The 48 tall item.
  final bool large;
  final bool disabled;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<bool>? onHoverChange;

  @override
  Widget build(BuildContext context) {
    final glyph = icon;
    final slot = leading;
    return _SideNavRow(
      label: label,
      leadingBuilder: glyph != null
          ? (_) => CarbonIcon(glyph)
          : slot != null
          ? (_) => slot
          : null,
      selected: current,
      emphasized: current,
      iconEmphasized: false,
      semanticsSelected: current,
      onPressed: onPressed,
      onLongPress: onLongPress,
      cancelOnLongPress: cancelOnLongPress,
      onDoublePressed: onDoublePressed,
      content: content,
      trailing: trailing,
      actions: actions,
      actionsMode: actionsMode,
      keepActionsRevealed: keepActionsRevealed,
      large: large,
      disabled: disabled,
      focusNode: focusNode,
      onFocusChange: onFocusChange,
      onHoverChange: onHoverChange,
    );
  }
}

/// An expandable branch: a header item that discloses [children] one level
/// deeper.
///
/// Expansion belongs to the host ([expanded], [onExpandedChanged]) because
/// opening a branch can start work (dial a connection) that a widget-local
/// toggle could not coordinate (deviation CSN-host-expanded). [children] are
/// built only while expanded.
///
/// An [active] branch is emphasised, and filled with the selected bar only
/// while collapsed, as upstream does. [hoverFill] false drops the hover fill
/// (deviation CSN-no-hover); a press still fills.
class CarbonSideNavMenu extends StatelessWidget {
  const CarbonSideNavMenu({
    super.key,
    required this.title,
    required this.expanded,
    required this.onExpandedChanged,
    required this.children,
    this.content,
    this.icon,
    this.leading,
    this.active = false,
    this.chevron = CarbonSideNavChevron.end,
    this.hoverFill = true,
    this.trailing = const <Widget>[],
    this.actions = const <Widget>[],
    this.actionsMode = CarbonSideNavActions.swap,
    this.keepActionsRevealed = false,
    this.large = false,
    this.focusNode,
    this.onFocusChange,
    this.onHoverChange,
  }) : assert(
         icon == null || leading == null,
         'Pass an icon or a leading widget, not both.',
       );

  /// The header's accessible name, and its text unless [content] replaces it.
  final String title;

  /// Free-form, non-interactive content shown in place of the title text;
  /// hidden from semantics, so [title] carries the spoken name.
  final Widget? content;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final List<Widget> children;
  final CarbonIcons? icon;
  final Widget? leading;
  final bool active;
  final CarbonSideNavChevron chevron;
  final bool hoverFill;
  final List<Widget> trailing;
  final List<Widget> actions;
  final CarbonSideNavActions actionsMode;
  final bool keepActionsRevealed;
  final bool large;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<bool>? onHoverChange;

  @override
  Widget build(BuildContext context) {
    final glyph = icon;
    final slot = leading;
    final swaps = chevron == CarbonSideNavChevron.swapsIcon;
    final inline = chevron == CarbonSideNavChevron.afterLabel;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final duration = CarbonMotion.resolve(context, CarbonMotion.fast02);

    // A tree chevron: down when open, toward the reading end when closed.
    Widget treeChevron() => AnimatedRotation(
      turns: expanded ? 0 : (rtl ? 0.25 : -0.25),
      duration: duration,
      child: const CarbonIcon(CarbonIcons.chevronDown),
    );

    Widget? leadingFor(bool pointerHovered) {
      if (swaps && pointerHovered) return treeChevron();
      if (glyph != null) return CarbonIcon(glyph);
      return slot;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _SideNavRow(
          label: title,
          content: content,
          leadingBuilder: swaps || glyph != null || slot != null
              ? leadingFor
              : null,
          labelGlyph: inline ? treeChevron() : null,
          endGlyph: swaps || inline
              ? null
              : AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: duration,
                  child: const CarbonIcon(CarbonIcons.chevronDown),
                ),
          selected: active && !expanded,
          emphasized: active,
          iconEmphasized: true,
          activeBranch: active,
          expanded: expanded,
          hoverFill: hoverFill,
          onPressed: () => onExpandedChanged(!expanded),
          trailing: trailing,
          actions: actions,
          actionsMode: actionsMode,
          keepActionsRevealed: keepActionsRevealed,
          large: large,
          focusNode: focusNode,
          onFocusChange: onFocusChange,
          onHoverChange: onHoverChange,
        ),
        if (expanded)
          CarbonSideNavScope.nested(
            context: context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
      ],
    );
  }
}

/// The one row painter behind links and menu headers, so their fills, bar,
/// slots and action layout cannot drift apart.
class _SideNavRow extends StatelessWidget {
  const _SideNavRow({
    required this.label,
    required this.selected,
    required this.emphasized,
    required this.onPressed,
    required this.trailing,
    required this.actions,
    required this.actionsMode,
    required this.keepActionsRevealed,
    required this.large,
    this.iconEmphasized = false,
    this.activeBranch = false,
    this.leadingBuilder,
    this.endGlyph,
    this.labelGlyph,
    this.semanticsSelected,
    this.expanded,
    this.hoverFill = true,
    this.onLongPress,
    this.cancelOnLongPress = false,
    this.onDoublePressed,
    this.content,
    this.disabled = false,
    this.focusNode,
    this.onFocusChange,
    this.onHoverChange,
  });

  final String label;

  /// Builds the leading slot's widget; told whether a pointer (never touch)
  /// is over the row. Null means no slot.
  final Widget? Function(bool pointerHovered)? leadingBuilder;
  final Widget? endGlyph;

  /// A glyph that follows the label directly rather than the end of the row.
  final Widget? labelGlyph;

  /// Fill and start bar.
  final bool selected;

  /// Primary text and icon colour at rest, and 600 weight.
  final bool emphasized;

  /// Primary icon colour at rest. Upstream raises it for an active menu only,
  /// never for a current link.
  final bool iconEmphasized;

  /// An active menu header, which hovers as selected even while expanded.
  final bool activeBranch;
  final bool? semanticsSelected;
  final bool? expanded;
  final bool hoverFill;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool cancelOnLongPress;
  final VoidCallback? onDoublePressed;
  final Widget? content;
  final List<Widget> trailing;
  final List<Widget> actions;
  final CarbonSideNavActions actionsMode;
  final bool keepActionsRevealed;
  final bool large;
  final bool disabled;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<bool>? onHoverChange;

  Widget _withLabelGlyph(CarbonThemeData theme, Color color, Widget label) {
    final glyph = labelGlyph;
    if (glyph == null) return label;
    return Row(
      children: <Widget>[
        Flexible(child: label),
        const SizedBox(width: CarbonSpacing.spacing02),
        IconTheme(
          data: IconThemeData(color: color, size: theme.iconSize),
          child: glyph,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final scope = CarbonSideNavScope.of(context);
    // Under touch the actions are always shown, so the marks sit inboard of
    // them instead of being covered.
    final stacked = actionsMode == CarbonSideNavActions.swap && !theme.isTouch;
    final interactive = onPressed != null && !disabled;
    final minHeight = math.max(large ? 48.0 : 32.0, theme.minTarget);
    final start = scope.inset + scope.depth * scope.stepFor(theme);
    final hasTrailing = trailing.isNotEmpty;
    final hasActions = actions.isNotEmpty;
    final hasTail = hasTrailing || hasActions;

    Widget row(bool hovered, bool focusWithin) {
      final hot = hovered && !disabled;
      final revealed =
          theme.isTouch || hovered || focusWithin || keepActionsRevealed;
      final Color? fill = selected
          ? colors.backgroundSelected
          : hot && hoverFill
          ? (activeBranch ? colors.backgroundSelected : colors.backgroundHover)
          : null;
      final textColor = disabled
          ? colors.textDisabled
          : (emphasized || hot)
          ? colors.textPrimary
          : colors.textSecondary;
      final iconColor = disabled
          ? colors.iconDisabled
          : iconEmphasized
          ? colors.iconPrimary
          : colors.iconSecondary;
      final base = scope.depth == 0
          ? theme.typography.heading
          : theme.typography.control;
      final style = base.copyWith(
        color: textColor,
        fontWeight: emphasized ? FontWeight.w600 : null,
      );
      final leadingWidget = leadingBuilder?.call(hovered && !theme.isTouch);

      Widget passThrough(Widget child) => interactive
          ? MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: onPressed,
                child: child,
              ),
            )
          : child;

      final trailingRow = hasTrailing
          ? passThrough(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var i = 0; i < trailing.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: CarbonSpacing.spacing02),
                    trailing[i],
                  ],
                ],
              ),
            )
          : null;

      Widget? tail;
      if (hasTail) {
        if (stacked) {
          tail = Stack(
            alignment: AlignmentDirectional.centerEnd,
            children: <Widget>[
              if (trailingRow != null)
                hasActions
                    ? Visibility(
                        visible: !revealed,
                        maintainState: true,
                        maintainAnimation: true,
                        maintainSize: true,
                        maintainSemantics: true,
                        child: trailingRow,
                      )
                    : trailingRow,
              if (hasActions)
                revealedActionsCell(visible: revealed, actions: actions),
            ],
          );
        } else {
          tail = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ?trailingRow,
              if (hasActions)
                revealedActionsCell(visible: revealed, actions: actions),
            ],
          );
        }
      }

      final cell = CarbonInteraction(
        onPressed: interactive ? onPressed : null,
        onLongPress: onLongPress,
        cancelOnLongPress: cancelOnLongPress,
        onDoublePressed: onDoublePressed,
        focusNode: focusNode,
        onFocusChange: onFocusChange,
        onHoverChange: onHoverChange,
        label: label,
        selected: semanticsSelected,
        expanded: expanded,
        excludeChildSemantics: true,
        builder: (context, state, _) => CarbonFocusRing(
          visible: state.focusVisible,
          child: ColoredBox(
            color: state.pressed
                ? colors.backgroundActive
                : const Color(0x00000000),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: start,
                  end: hasTail ? CarbonSpacing.spacing03 : scope.endInset,
                  top: CarbonSpacing.spacing02,
                  bottom: CarbonSpacing.spacing02,
                ),
                // heightFactor keeps a row at its own height inside a bounded
                // parent instead of filling it.
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  heightFactor: 1,
                  child: Row(
                    children: <Widget>[
                      if (leadingBuilder != null) ...<Widget>[
                        IconTheme(
                          data: IconThemeData(
                            color: iconColor,
                            size: theme.iconSize,
                          ),
                          child: SizedBox.square(
                            dimension: theme.iconSize,
                            child: Center(child: leadingWidget),
                          ),
                        ),
                        const SizedBox(width: CarbonSpacing.spacing03),
                      ],
                      Expanded(
                        child: _withLabelGlyph(
                          theme,
                          iconColor,
                          DefaultTextStyle(
                            style: style,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            child: content ?? Text(label),
                          ),
                        ),
                      ),
                      if (endGlyph != null) ...<Widget>[
                        const SizedBox(width: CarbonSpacing.spacing03),
                        IconTheme(
                          data: IconThemeData(
                            color: iconColor,
                            size: theme.iconSize,
                          ),
                          child: endGlyph!,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // The bar paints above the fill so a hovered or pressed row never
      // hides it.
      return DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: selected
              ? BorderDirectional(
                  start: BorderSide(
                    color: colors.borderInteractive,
                    width: CarbonBorders.selectedTab,
                  ),
                )
              : null,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: fill),
          child: Row(
            children: <Widget>[
              Expanded(child: cell),
              if (tail != null) ...<Widget>[
                tail,
                SizedBox(width: scope.endInset),
              ],
            ],
          ),
        ),
      );
    }

    return RevealedActionsHost(
      builder: (context, hovered, focusWithin) => row(hovered, focusWithin),
    );
  }
}
