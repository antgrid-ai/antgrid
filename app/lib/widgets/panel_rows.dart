import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_touch_sizing.dart';

/// Uppercase mono section header, mirroring `AbMenu`'s header treatment
/// (`app/lib/design/widgets/ab_menu.dart`) so grouped panels read as one
/// popup system.
class PanelSectionHeader extends StatelessWidget {
  const PanelSectionHeader(this.label, {super.key, this.mono = true});

  final String label;

  /// False for a panel of navigational chrome (e.g. the workspace menu's
  /// "Workspace" header) rather than a picker over identifiers — sans is the
  /// font-token rule for chrome, mono for data (see app/AGENTS.md's Design
  /// Rules). Defaults true: every existing caller here is an
  /// environment/branch/project picker, where the rows below ARE identifiers.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final style = mono ? AbTokens.monoStyle : AbTokens.sansStyle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Text(
        label.toUpperCase(),
        style: style(
          fontSize: AbTokens.fontXs,
          letterSpacing: 0.66,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}

/// Hover-highlighted row: `[icon] label ... [trailing] [check when
/// selected]`. Visually mirrors `_MenuItemTile` in `ab_menu.dart` — same
/// padding, radius, and hover background — so panel rows and menu items read
/// as the same control under different popup content. Like `_MenuItemTile` it
/// is keyboard-operable: it takes focus (highlighted the same as hover) and
/// Enter/Space/NumpadEnter activate it, so `showAbPanel` rows are reachable by
/// Tab traversal, not mouse-only.
class PanelRow extends StatefulWidget {
  const PanelRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
    this.mono = true,
  });

  final String icon;
  final String label;
  final bool selected;

  /// Pass `null` to render the row in a disabled state (opacity 0.4, no
  /// hover, no focus, no tap) — same contract as [AbIconButton.onTap]. Lets a
  /// caller keep a row VISIBLE-BUT-INACTIVE ("nothing to act on yet") rather
  /// than omit it, so a menu whose every action currently has nothing to act
  /// on doesn't render empty.
  final VoidCallback? onTap;
  final Widget? trailing;

  /// False for a panel of navigational chrome rather than a picker over
  /// identifiers — see [PanelSectionHeader.mono], same rule and same default.
  final bool mono;

  @override
  State<PanelRow> createState() => _PanelRowState();
}

class _PanelRowState extends State<PanelRow> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final disabled = widget.onTap == null;
    // Treat keyboard focus the same as pointer hover for the highlight — one
    // "active row" state for either input mode, matching `_MenuItemTile`.
    final active = !disabled && (_hover || _focused);
    final baseFg = active ? p.textPrimary : p.textSecondary;
    final baseIconFg = active ? p.textPrimary : p.textMuted;
    // Same dim-the-glyph contract as AbIconButton.onTap: null — no Opacity
    // wrap, just alpha on the two colors already carrying this row's content.
    final fg = disabled ? baseFg.withValues(alpha: baseFg.a * 0.4) : baseFg;
    final iconFg = disabled
        ? baseIconFg.withValues(alpha: baseIconFg.a * 0.4)
        : baseIconFg;

    final row = Container(
      // Same floor as AbLiveMenuRow: a panel row shares popups with menu rows
      // and must not be the one short target among them on a phone.
      constraints: BoxConstraints(minHeight: AbTouchSizing.extentOf(context)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: active ? p.bgHover : null,
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 9),
            child: AbIcon(widget.icon, size: 13, color: iconFg),
          ),
          Expanded(
            child: Text(
              widget.label,
              overflow: TextOverflow.ellipsis,
              style: (widget.mono ? AbTokens.monoStyle : AbTokens.sansStyle)(
                fontSize: AbTokens.fontSm,
                color: fg,
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
          if (widget.selected) ...[
            const SizedBox(width: AbTokens.space6),
            AbIcon(AbIcons.check, size: 12, color: p.accent),
          ],
        ],
      ),
    );

    if (disabled) return row;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) {
        if (_hover != v) setState(() => _hover = v);
      },
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap!();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

/// Muted single-line hint row (non-interactive) — e.g. "No machines on this
/// account".
class PanelHint extends StatelessWidget {
  const PanelHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        text,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}
