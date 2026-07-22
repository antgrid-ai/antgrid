import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';
import 'ab_kbd.dart';

class AbMobileCta extends StatefulWidget {
  const AbMobileCta({
    super.key,
    required this.active,
    required this.onTap,
    this.kbdHint = '⌘M',
    this.activeLabel = 'Mobile · connected',
    this.inactiveLabel = 'Enable mobile access',
  });

  final bool active;
  final VoidCallback onTap;

  /// Keyboard hint chip shown in the inactive state. Pass `null` to hide it.
  final String? kbdHint;

  /// Label text for each state. Defaults match the original always-on CTA;
  /// callers that drive an explicit on/off toggle override both.
  final String activeLabel;
  final String inactiveLabel;

  @override
  State<AbMobileCta> createState() => _AbMobileCtaState();
}

class _AbMobileCtaState extends State<AbMobileCta>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    if (widget.active) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AbMobileCta oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final running = p.statusRunning;
    final bg = widget.active ? running.withValues(alpha: 0.10) : p.bgHover;
    final fg = widget.active ? running : p.textPrimary;
    final border = widget.active
        ? running.withValues(alpha: 0.35)
        : p.borderStrong;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: AbTokens.borderRadiusFull,
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.active)
                AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, _) => Opacity(
                    opacity: 1.0 - _ctrl.value * 0.45,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: running,
                        borderRadius: AbTokens.borderRadiusFull,
                      ),
                    ),
                  ),
                )
              else
                AbIcon(AbIcons.deviceMobile, size: 13, color: p.statusThinking),
              const SizedBox(width: 8),
              Text(
                widget.active ? widget.activeLabel : widget.inactiveLabel,
                style: TextStyle(
                  fontSize: AbTokens.fontSm,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
              if (!widget.active && widget.kbdHint != null) ...[
                const SizedBox(width: 8),
                AbKbd(widget.kbdHint!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
