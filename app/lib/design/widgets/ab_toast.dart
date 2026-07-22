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
          // Expand the text so the action sits on the trailing edge. Only with
          // an action present: action toasts are always laid out in bounded
          // width, whereas action-less toasts render in width-unbounded overlays
          // where Expanded would assert.
          if (hasAction) Expanded(child: textColumn) else textColumn,
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
      child: Material(color: Colors.transparent, child: toast),
    ),
  );
  overlay.insert(entry);
  Timer(duration, remove);
}
