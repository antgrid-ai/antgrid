import 'dart:async';

import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import '../widgets/ab_icon.dart';

class AbToast extends StatelessWidget {
  const AbToast({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.iconColor,
    this.actionLabel,
    this.onAction,
  });

  final String icon;
  final String title;
  final String description;

  /// Overrides the icon dot color. Defaults to [AbColors.statusRunning].
  final Color? iconColor;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final hasAction = actionLabel != null;
    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AbTokens.fontMd,
            fontWeight: FontWeight.w500,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          description,
          style: TextStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
        ),
      ],
    );
    return Container(
      constraints: const BoxConstraints(minWidth: 280),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: p.bgRaised,
        borderRadius: AbTokens.borderRadius8,
        border: Border.all(color: p.borderStrong),
        boxShadow: [
          BoxShadow(
            color: const Color(0xB3000000),
            blurRadius: 48,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (iconColor ?? p.statusRunning).withValues(alpha: 0.15),
              borderRadius: AbTokens.borderRadiusFull,
            ),
            child: AbIcon(icon, size: 12, color: iconColor ?? p.statusRunning),
          ),
          const SizedBox(width: 10),
          // Both flex so long text WRAPS under the host's width cap instead
          // of overflowing the Row. Expanded (tight) pins the action to the
          // trailing edge; loose Flexible keeps action-less toasts
          // shrink-wrapped below the cap. Either way the host must bound the
          // Row's width — see showAbToastOverlay's ConstrainedBox.
          if (hasAction)
            Expanded(child: textColumn)
          else
            Flexible(child: textColumn),
          if (hasAction) ...[
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: p.bgHover,
                  border: Border.all(color: p.borderDefault),
                  borderRadius: AbTokens.borderRadius3,
                ),
                child: Text(
                  actionLabel!,
                  style: TextStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows [toast] as a transient overlay pinned to the top-right, auto-dismissing
/// after [duration]. No-ops when no [Overlay] is in scope. Safe if the Overlay
/// is torn down before the timer fires (route swap, teardown, hot restart).
void showAbToastOverlay(
  BuildContext context, {
  required AbToast toast,
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  showAbToastOn(overlay, toast: toast, duration: duration);
}

/// [showAbToastOverlay] for a caller holding the [OverlayState] itself.
///
/// `Overlay.maybeOf` resolves through an inherited marker that each overlay
/// ENTRY plants, so it answers only from inside a mounted route — a caller
/// working from a navigator key (no widget of its own, firing long after the
/// screen that started it) has no such context and would silently show nothing.
void showAbToastOn(
  OverlayState overlay, {
  required AbToast toast,
  Duration duration = const Duration(seconds: 4),
}) {
  late final OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    // entry.mounted guards a bare remove() against the Overlay being detached
    // first, which would otherwise trip a debug assertion when the timer fires
    // after disposal.
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      top: MediaQuery.paddingOf(ctx).top + AbTokens.space16,
      right: AbTokens.space16,
      // The overlay theater hands a top/right-only Positioned unbounded
      // width, and the toast's flex children assert without a finite max —
      // cap it, screen-fitted on narrow phones. The clamp also floors at 0:
      // a window dragged below the margins would otherwise produce negative
      // (invalid) constraints.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(ctx).width - AbTokens.space16 * 2).clamp(
            0.0,
            360.0,
          ),
        ),
        child: Material(color: Colors.transparent, child: toast),
      ),
    ),
  );
  overlay.insert(entry);
  Timer(duration, remove);
}
