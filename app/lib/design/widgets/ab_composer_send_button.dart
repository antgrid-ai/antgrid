import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_focus_ring.dart';
import 'ab_icon.dart';
import 'ab_loading.dart';
import 'ab_tap_target.dart';
import 'ab_touch_sizing.dart';

/// Filled accent send key — a composer's one solid-fill element, so the
/// primary action outranks the ghost chips and icon buttons around it.
/// Shared by the New Session composer and the transcript composer so the two
/// read as the same instrument.
///
/// `onTap: null` renders the disabled contract (0.4 opacity, no
/// interaction); [busy] keeps the accent fill and swaps the glyph for a
/// pulsing dot while the session is starting.
///
/// [icon]/[color] override the glyph and fill for sibling actions that must
/// occupy the same key — e.g. the transcript's Stop (error fill, stop glyph).
/// A custom fill keeps its color on hover; only the default accent fill has
/// a distinct hover shade.
class ComposerSendButton extends StatefulWidget {
  const ComposerSendButton({
    super.key,
    this.onTap,
    this.busy = false,
    this.icon,
    this.color,
  });

  final VoidCallback? onTap;
  final bool busy;
  final String? icon;
  final Color? color;

  @override
  State<ComposerSendButton> createState() => _ComposerSendButtonState();
}

class _ComposerSendButtonState extends State<ComposerSendButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final enabled = widget.onTap != null && !widget.busy;
    final live = enabled || widget.busy;
    final fill = widget.color ?? p.accent;
    final hoverFill = widget.color ?? p.accentHighlight;
    // Only a phone reserves the touch footprint. Elsewhere a minSize equal to
    // the key's own box keeps it at its drawn size, where the default would
    // grow it on a tablet.
    final targetSize = AbTouchSizing.extentOf(context) > 0
        ? AbTokens.touchControlMin
        : AbTokens.iconButtonBox;

    final Widget visual = AnimatedContainer(
      duration: AbTokens.motionSnap,
      width: AbTokens.iconButtonBox,
      height: AbTokens.iconButtonBox,
      decoration: BoxDecoration(
        color: live ? (_hovered && enabled ? hoverFill : fill) : p.bgElevated,
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Center(
        child: widget.busy
            ? AbLoadingDot(size: 10, color: p.accentForeground)
            : AbIcon(
                widget.icon ?? AbIcons.send,
                size: AbTokens.iconButtonGlyph,
                color: live ? p.accentForeground : p.textMuted,
              ),
      ),
    );

    if (!enabled) {
      // Busy keeps full opacity — the fill + dot read as "working", not off.
      // The footprint is reserved while inert so the key doesn't resize the
      // row when it toggles between send and disabled.
      return AbTapTarget(
        minSize: targetSize,
        child: widget.busy
            ? visual
            : Opacity(opacity: AbTokens.opacityDisabled, child: visual),
      );
    }

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) {
        if (_hovered != v) setState(() => _hovered = v);
      },
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      // The tap surface wraps the footprint so the touch margin around the
      // visual claims hits on phones.
      child: AbTapTarget(
        minSize: targetSize,
        onTap: widget.onTap,
        child: AbFocusRing(
          focused: _focused,
          borderRadius: AbTokens.borderRadius3,
          child: visual,
        ),
      ),
    );
  }
}
