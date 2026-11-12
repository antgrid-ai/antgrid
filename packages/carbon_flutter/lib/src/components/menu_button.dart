import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/popup.dart';
import 'button.dart';
import 'menu.dart';

typedef _TriggerBuilder =
    Widget Function(
      BuildContext context,
      bool open,
      VoidCallback toggle,
      FocusNode focusNode,
      Set<String>? controls,
    );

typedef _Decorator = Widget Function(BuildContext context, Widget menu);

// The height a button of [size] renders at, mirroring CarbonButton so a menu's
// rows can match their trigger.
double _buttonHeight(CarbonThemeData theme, CarbonButtonSize? size) {
  if (size == CarbonButtonSize.extraSmall && !theme.isTouch) {
    return CarbonSizes.xs;
  }
  return math.max(size?.height ?? theme.controlHeight, theme.minTarget);
}

/// The trigger's chevron: one glyph that turns half a turn as the menu opens,
/// as Carbon rotates its caret, with no turn under reduced motion.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0.5 : 0,
    duration: CarbonMotion.resolve(context, CarbonMotion.fast02),
    curve: CarbonMotion.standard,
    child: const CarbonIcon(CarbonIcons.chevronDown),
  );
}

/// Owns the controller and focus node every menu trigger needs, wires them to
/// a [CarbonMenu] and rebuilds the trigger as the menu opens and closes.
class _MenuTrigger extends StatefulWidget {
  const _MenuTrigger({
    required this.entries,
    required this.builder,
    required this.alignment,
    this.preferAbove = false,
    this.size,
    this.focusNode,
    this.onDismissed,
    this.onOpenChanged,
    this.semanticLabel,
    this.enabled = true,
    this.decorate,
  });

  final List<CarbonMenuEntry> entries;
  final _TriggerBuilder builder;
  final CarbonPopupAlignment alignment;
  final bool preferAbove;

  /// The trigger's size; the menu's rows take its height.
  final CarbonButtonSize? size;
  final FocusNode? focusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;
  final ValueChanged<bool>? onOpenChanged;
  final String? semanticLabel;

  /// A disabled trigger closes its open menu: a dimmed control must not keep
  /// commands operable.
  final bool enabled;

  /// Places the menu and its anchor among sibling controls without making
  /// those siblings part of the anchor.
  final _Decorator? decorate;

  @override
  State<_MenuTrigger> createState() => _MenuTriggerState();
}

class _MenuTriggerState extends State<_MenuTrigger> {
  final CarbonPopupController _controller = CarbonPopupController();
  FocusNode? _ownedNode;
  bool _reportedOpen = false;
  late final String _menuId = 'carbon-menu-$hashCode';

  FocusNode get _node => widget.focusNode ?? (_ownedNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(_MenuTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _controller.isOpen) _controller.close();
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _ownedNode?.dispose();
    super.dispose();
  }

  void _changed() {
    final open = _controller.isOpen;
    if (open != _reportedOpen) {
      _reportedOpen = open;
      final report = widget.onOpenChanged;
      if (report != null) {
        // A close forced from didUpdateWidget lands mid-build, where the
        // owner's setState would assert; it hears about it after the frame.
        if (SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
          SchedulerBinding.instance.addPostFrameCallback((_) => report(open));
        } else {
          report(open);
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final open = _controller.isOpen;
    final size = widget.size;
    final menu = CarbonMenu(
      controller: _controller,
      entries: widget.entries,
      alignment: widget.alignment,
      preferAbove: widget.preferAbove,
      rowHeight: size == null
          ? null
          : _buttonHeight(CarbonTheme.of(context), size),
      restoreFocus: _node,
      onDismissed: widget.onDismissed,
      semanticLabel: widget.semanticLabel,
      semanticIdentifier: _menuId,
      child: widget.builder(
        context,
        open,
        _controller.toggle,
        _node,
        open ? <String>{_menuId} : null,
      ),
    );
    return widget.decorate?.call(context, menu) ?? menu;
  }
}

// One node carrying the trigger's name, activation and expanded state, so a
// screen reader hears "Actions, button, collapsed" rather than a nameless
// expanded container beside a collapsed button. While open it also names the
// menu it controls.
Widget _expandable(bool open, Set<String>? controls, Widget trigger) =>
    MergeSemantics(
      child: Semantics(
        expanded: open,
        controlsNodes: controls,
        child: trigger,
      ),
    );

/// A labelled button that opens a [CarbonMenu] of commands.
///
/// For commands, not for choosing a value: a menu button has no value of its
/// own and must not stand in for a form field. The chevron flips while the
/// menu is open and the trigger announces its expanded state. [enabled] false
/// disables the trigger.
class CarbonMenuButton extends StatelessWidget {
  const CarbonMenuButton({
    super.key,
    required this.label,
    required this.entries,
    this.kind = CarbonButtonKind.primary,
    this.size,
    this.enabled = true,
    this.alignment = CarbonPopupAlignment.start,
    this.preferAbove = false,
    this.focusNode,
    this.onDismissed,
    this.onOpenChanged,
    this.semanticLabel,
    this.triggerSemanticLabel,
    this.maxLines,
    this.leading,
  }) : assert(
         kind == CarbonButtonKind.primary ||
             kind == CarbonButtonKind.tertiary ||
             kind == CarbonButtonKind.ghost,
         'Carbon menu buttons are primary, tertiary or ghost',
       );

  final String label;
  final List<CarbonMenuEntry> entries;

  /// Primary, tertiary or ghost, the treatments Carbon allows for menu
  /// buttons.
  final CarbonButtonKind kind;
  final CarbonButtonSize? size;
  final bool enabled;
  final CarbonPopupAlignment alignment;

  /// Opens the menu above the trigger when it fits (Carbon's `top` menu
  /// alignment), for triggers that sit below content the menu must not cover.
  final bool preferAbove;

  /// The trigger's focus node; focus returns to it when the menu closes.
  final FocusNode? focusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

  /// Called with true when the menu opens and false when it closes, including
  /// the close that precedes an item's callback. Not called if the trigger
  /// unmounts while open. Lets an owner keep a hover-revealed trigger
  /// mounted while the pointer is over the menu, which sits outside it.
  final ValueChanged<bool>? onOpenChanged;

  /// The open menu's announced name; defaults to [label].
  final String? semanticLabel;

  /// The trigger's announced name; defaults to [label]. Use it when the
  /// visible label is a value (a selected machine, say) that alone does not
  /// say what the control changes.
  final String? triggerSemanticLabel;

  /// Clamps the trigger's label; see [CarbonButton.maxLines].
  final int? maxLines;

  /// A mark before the trigger's label; see [CarbonButton.leading].
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return _MenuTrigger(
      entries: entries,
      alignment: alignment,
      preferAbove: preferAbove,
      size: size,
      focusNode: focusNode,
      onDismissed: onDismissed,
      onOpenChanged: onOpenChanged,
      semanticLabel: semanticLabel ?? label,
      enabled: enabled,
      builder: (context, open, toggle, node, controls) => _expandable(
        open,
        controls,
        CarbonButton(
          label: label,
          semanticLabel: triggerSemanticLabel,
          maxLines: maxLines,
          leading: leading,
          kind: kind,
          size: size,
          // Carbon's 12rem floor on primary and tertiary triggers.
          minWidth: kind == CarbonButtonKind.ghost ? null : 192,
          focusNode: node,
          icon: _Chevron(open: open),
          onPressed: enabled ? toggle : null,
        ),
      ),
    );
  }
}

/// An icon-only trigger for secondary commands, three dots by default.
///
/// The footprint is 32 square in compact density and [CarbonThemeData.touchTarget] in touch. The
/// accessible name defaults to the localized "Options"; give a more specific
/// [semanticLabel] when several overflow menus share a screen. An item
/// callback may push a route: the menu has closed and focus has returned to
/// this trigger by then.
class CarbonOverflowMenu extends StatelessWidget {
  const CarbonOverflowMenu({
    super.key,
    required this.entries,
    this.horizontal = false,
    this.enabled = true,
    this.size,
    this.alignment = CarbonPopupAlignment.end,
    this.preferAbove = false,
    this.icon,
    this.focusNode,
    this.onDismissed,
    this.onOpenChanged,
    this.semanticLabel,
    this.menuLabel,
  });

  final List<CarbonMenuEntry> entries;

  /// Three horizontal dots instead of vertical.
  final bool horizontal;
  final bool enabled;
  final CarbonButtonSize? size;

  /// The menu's edge that lines up with the trigger; the end by default so a
  /// trigger at the edge of a row or panel keeps the menu on screen.
  final CarbonPopupAlignment alignment;

  /// Opens the menu above the trigger when it fits.
  final bool preferAbove;

  /// Replaces the dots (Carbon's `renderIcon`); [horizontal] is then ignored.
  final Widget? icon;
  final FocusNode? focusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

  /// Called with true when the menu opens and false when it closes, including
  /// the close that precedes an item's callback. Not called if the trigger
  /// unmounts while open. Lets an owner keep a hover-revealed trigger
  /// mounted while the pointer is over the menu, which sits outside it.
  final ValueChanged<bool>? onOpenChanged;

  /// The trigger's accessible name.
  final String? semanticLabel;

  /// The open menu's accessible name.
  final String? menuLabel;

  @override
  Widget build(BuildContext context) {
    final name = semanticLabel ?? CarbonLocalizations.of(context).moreOptions;
    return _MenuTrigger(
      entries: entries,
      alignment: alignment,
      preferAbove: preferAbove,
      size: size,
      focusNode: focusNode,
      onDismissed: onDismissed,
      onOpenChanged: onOpenChanged,
      semanticLabel: menuLabel ?? name,
      enabled: enabled,
      builder: (context, open, toggle, node, controls) {
        final theme = CarbonTheme.of(context);
        return _expandable(
          open,
          controls,
          // The open trigger takes the menu's layer and shadow so the two
          // read as one surface. The wrapper is always present so opening
          // never remounts the button.
          DecoratedBox(
            decoration: open
                ? BoxDecoration(
                    color: theme.layer(CarbonLayer.of(context)),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: theme.colors.shadow,
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  )
                : const BoxDecoration(),
            child: CarbonButton.iconOnly(
              icon:
                  icon ??
                  CarbonIcon(
                    horizontal
                        ? CarbonIcons.overflowMenuHorizontal
                        : CarbonIcons.overflowMenuVertical,
                  ),
              semanticLabel: name,
              size: size,
              focusNode: node,
              // An open trigger stays on the layer fill the wrapper paints;
              // Carbon's open-and-hover rule outranks the ghost hover and
              // active fills.
              hoverFill: !open,
              onPressed: enabled ? toggle : null,
            ),
          ),
        );
      },
    );
  }
}

/// A primary action with a separate trigger for related alternatives (Carbon's
/// combo button).
///
/// The action and the trigger are two controls: each takes focus on its own,
/// has its own accessible name and its own 32 / touch target, and activating one
/// never activates the other. Disable the action with a null [onPressed]
/// while the menu stays usable, or the reverse with [menuEnabled].
class CarbonSplitButton extends StatelessWidget {
  const CarbonSplitButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.entries,
    this.kind = CarbonButtonKind.primary,
    this.size,
    this.menuEnabled = true,
    this.alignment = CarbonPopupAlignment.end,
    this.focusNode,
    this.triggerFocusNode,
    this.onDismissed,
    this.onOpenChanged,
    this.menuTriggerLabel,
    this.menuLabel,
  }) : assert(
         kind == CarbonButtonKind.primary || kind == CarbonButtonKind.tertiary,
         'Carbon combo buttons are primary or tertiary',
       );

  final String label;

  /// The primary action. Null disables the action, not the menu.
  final VoidCallback? onPressed;
  final List<CarbonMenuEntry> entries;
  final CarbonButtonKind kind;
  final CarbonButtonSize? size;
  final bool menuEnabled;
  final CarbonPopupAlignment alignment;

  /// Focus node of the primary action.
  final FocusNode? focusNode;

  /// Focus node of the menu trigger; focus returns to it when the menu closes.
  final FocusNode? triggerFocusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

  /// Called with true when the menu opens and false when it closes, including
  /// the close that precedes an item's callback. Not called if the trigger
  /// unmounts while open. Lets an owner keep a hover-revealed trigger
  /// mounted while the pointer is over the menu, which sits outside it.
  final ValueChanged<bool>? onOpenChanged;

  /// The menu trigger's accessible name; the localized "Open menu" by default.
  final String? menuTriggerLabel;

  /// The open menu's accessible name; the action's [label] by default.
  final String? menuLabel;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final triggerName =
        menuTriggerLabel ?? CarbonLocalizations.of(context).openMenu;
    // Carbon keeps the whole control at 160 px or more: the action takes what
    // the square trigger and the 1px rule leave, never under 111 px.
    final actionMinWidth = math.max(
      111.0,
      160 - CarbonBorders.hairline - _buttonHeight(theme, size),
    );
    return _MenuTrigger(
      entries: entries,
      alignment: alignment,
      size: size,
      focusNode: triggerFocusNode,
      onDismissed: onDismissed,
      onOpenChanged: onOpenChanged,
      semanticLabel: menuLabel ?? label,
      enabled: menuEnabled,
      // Only the trigger anchors the menu: the action beside it is outside the
      // menu's tap group, so pressing it dismisses an open menu.
      decorate: (context, menu) => IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 239),
                child: CarbonButton(
                  label: label,
                  kind: kind,
                  size: size,
                  minWidth: actionMinWidth,
                  focusNode: focusNode,
                  onPressed: onPressed,
                ),
              ),
            ),
            SizedBox(
              width: CarbonBorders.hairline,
              child: ColoredBox(color: theme.colors.buttonSeparator),
            ),
            menu,
          ],
        ),
      ),
      builder: (context, open, toggle, node, controls) => _expandable(
          open,
          controls,
          CarbonButton.iconOnly(
            icon: _Chevron(open: open),
            semanticLabel: triggerName,
            kind: kind,
            size: size,
            focusNode: node,
            onPressed: menuEnabled ? toggle : null,
          ),
        ),
    );
  }
}
