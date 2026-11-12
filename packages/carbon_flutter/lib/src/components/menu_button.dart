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
    );

/// Owns the controller and focus node every menu trigger needs, wires them to
/// a [CarbonMenu] and rebuilds the trigger as the menu opens and closes.
class _MenuTrigger extends StatefulWidget {
  const _MenuTrigger({
    required this.entries,
    required this.builder,
    required this.alignment,
    this.focusNode,
    this.onDismissed,
    this.closeOnToggle = true,
    this.semanticLabel,
  });

  final List<CarbonMenuEntry> entries;
  final _TriggerBuilder builder;
  final CarbonPopupAlignment alignment;
  final FocusNode? focusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;
  final bool closeOnToggle;
  final String? semanticLabel;

  @override
  State<_MenuTrigger> createState() => _MenuTriggerState();
}

class _MenuTriggerState extends State<_MenuTrigger> {
  final CarbonPopupController _controller = CarbonPopupController();
  FocusNode? _ownedNode;

  FocusNode get _node => widget.focusNode ?? (_ownedNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _ownedNode?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CarbonMenu(
      controller: _controller,
      entries: widget.entries,
      alignment: widget.alignment,
      closeOnToggle: widget.closeOnToggle,
      restoreFocus: _node,
      onDismissed: widget.onDismissed,
      semanticLabel: widget.semanticLabel,
      child: widget.builder(context, _controller.isOpen, _controller.toggle, _node),
    );
  }
}

// One node carrying the trigger's name, activation and expanded state, so a
// screen reader hears "Actions, button, collapsed" rather than a nameless
// expanded container beside a collapsed button.
Widget _expandable(bool open, Widget trigger) => MergeSemantics(
  child: Semantics(expanded: open, child: trigger),
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
    this.focusNode,
    this.onDismissed,
    this.semanticLabel,
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

  /// The trigger's focus node; focus returns to it when the menu closes.
  final FocusNode? focusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

  /// The open menu's announced name; defaults to [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return _MenuTrigger(
      entries: entries,
      alignment: alignment,
      focusNode: focusNode,
      onDismissed: onDismissed,
      semanticLabel: semanticLabel ?? label,
      builder: (context, open, toggle, node) => _expandable(
        open,
        CarbonButton(
          label: label,
          kind: kind,
          size: size,
          focusNode: node,
          icon: CarbonIcon(open ? CarbonIcons.chevronUp : CarbonIcons.chevronDown),
          onPressed: enabled ? toggle : null,
        ),
      ),
    );
  }
}

/// An icon-only trigger for secondary commands, three dots by default.
///
/// The footprint is 32 square in compact density and 48 in touch. The
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
    this.focusNode,
    this.onDismissed,
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
  final FocusNode? focusNode;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;

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
      focusNode: focusNode,
      onDismissed: onDismissed,
      semanticLabel: menuLabel ?? name,
      builder: (context, open, toggle, node) => _expandable(
        open,
        CarbonButton.iconOnly(
          icon: CarbonIcon(
            horizontal
                ? CarbonIcons.overflowMenuHorizontal
                : CarbonIcons.overflowMenuVertical,
          ),
          semanticLabel: name,
          size: size,
          focusNode: node,
          onPressed: enabled ? toggle : null,
        ),
      ),
    );
  }
}

/// A primary action with a separate trigger for related alternatives (Carbon's
/// combo button).
///
/// The action and the trigger are two controls: each takes focus on its own,
/// has its own accessible name and its own 32 / 48 target, and activating one
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

  /// The menu trigger's accessible name; the localized "Open menu" by default.
  final String? menuTriggerLabel;

  /// The open menu's accessible name.
  final String? menuLabel;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final triggerName =
        menuTriggerLabel ?? CarbonLocalizations.of(context).openMenu;
    return _MenuTrigger(
      entries: entries,
      alignment: alignment,
      focusNode: triggerFocusNode,
      onDismissed: onDismissed,
      semanticLabel: menuLabel,
      builder: (context, open, toggle, node) {
        final trigger = _expandable(
          open,
          CarbonButton.iconOnly(
            icon: CarbonIcon(
              open ? CarbonIcons.chevronUp : CarbonIcons.chevronDown,
            ),
            semanticLabel: triggerName,
            kind: kind,
            size: size,
            focusNode: node,
            onPressed: menuEnabled ? toggle : null,
          ),
        );
        return IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Flexible(
                child: CarbonButton(
                  label: label,
                  kind: kind,
                  size: size,
                  focusNode: focusNode,
                  onPressed: onPressed,
                ),
              ),
              SizedBox(
                width: CarbonBorders.hairline,
                child: ColoredBox(color: theme.colors.buttonSeparator),
              ),
              trigger,
            ],
          ),
        );
      },
    );
  }
}
