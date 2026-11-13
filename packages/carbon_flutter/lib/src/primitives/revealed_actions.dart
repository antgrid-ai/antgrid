import 'package:flutter/widgets.dart';

import '../foundations/tokens.dart';

/// Builds a row from whether the pointer is over it and whether focus is
/// anywhere inside it.
typedef RevealedActionsBuilder =
    Widget Function(BuildContext context, bool hovered, bool focusWithin);

/// Tracks pointer hover and focus-within for a whole row, so hover-revealed
/// actions outside the row's own interaction can follow both. Shared by the
/// contained list row and the side nav items so the two cannot drift.
///
/// The focus wrapper is neither focusable nor traversable: it only listens.
class RevealedActionsHost extends StatefulWidget {
  const RevealedActionsHost({super.key, required this.builder});

  final RevealedActionsBuilder builder;

  @override
  State<RevealedActionsHost> createState() => _RevealedActionsHostState();
}

class _RevealedActionsHostState extends State<RevealedActionsHost> {
  bool _hovered = false;

  // Read live in build rather than cached from onFocusChange: when the focused
  // descendant is disposed (a menu item under a trigger that unmounted), the
  // focus manager drops primary focus without notifying this ancestor, so a
  // cached flag would hold the row revealed until something else refocused it.
  final FocusNode _focus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'RevealedActionsHost',
  );

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _setHover(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: Focus(
        focusNode: _focus,
        onFocusChange: (_) => setState(() {}),
        child: widget.builder(context, _hovered, _focus.hasFocus),
      ),
    );
  }
}

/// The actions laid out in a row. Hidden actions keep their size, state,
/// semantics and focusability, so layout never shifts and keyboard users
/// reach them before they show.
Widget revealedActionsCell({
  required bool visible,
  required List<Widget> actions,
}) => Visibility(
  visible: visible,
  maintainState: true,
  maintainAnimation: true,
  maintainSize: true,
  maintainSemantics: true,
  maintainFocusability: true,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (var i = 0; i < actions.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(width: CarbonSpacing.spacing02),
        actions[i],
      ],
    ],
  ),
);
