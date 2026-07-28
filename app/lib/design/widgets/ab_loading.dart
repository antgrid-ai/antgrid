import 'package:flutter/material.dart';
import '../ab_tokens.dart';
import '../ab_colors.dart';

/// Terminal-native loading indicator — a pulsing cursor block.
///
/// Mimics a blinking terminal cursor to stay true to the dev-tool aesthetic.
/// Use [AbLoading] for general loading, [AbLoadingState] for loading
/// with a status message, and [AbLoadingOverlay] for inline spinners.
class AbLoading extends StatefulWidget {
  /// Optional status message shown below the cursor.
  final String? message;

  /// Size of the cursor block.
  final double size;

  const AbLoading({super.key, this.message, this.size = 14});

  @override
  State<AbLoading> createState() => _AbLoadingState();
}

class _AbLoadingState extends State<AbLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween(
      begin: 0.2,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  // Started here (not initState) so the reduce-motion flag is readable, and
  // because didChangeDependencies re-fires on MediaQuery change — a live
  // reduce-motion flip stops/restarts the pulse without extra plumbing.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      // Pin mid-pulse so the indicator still reads "busy", just statically.
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _opacity,
            builder: (context, _) => Container(
              width: widget.size,
              height: widget.size * 1.4,
              decoration: BoxDecoration(
                color: context.antgrid.accent.withValues(alpha: _opacity.value),
                borderRadius: AbTokens.borderRadius3,
              ),
            ),
          ),
          if (widget.message != null) ...[
            const SizedBox(height: AbTokens.space12),
            Text(
              widget.message!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline loading indicator — a small pulsing dot for use inside
/// buttons, bars, and compact spaces. Replaces CircularProgressIndicator.
class AbLoadingDot extends StatefulWidget {
  final double size;
  final Color? color;

  const AbLoadingDot({super.key, this.size = 12, this.color});

  @override
  State<AbLoadingDot> createState() => _AbLoadingDotState();
}

class _AbLoadingDotState extends State<AbLoadingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scale = Tween(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  // See _AbLoadingState.didChangeDependencies — same reduce-motion contract.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      // Pin mid-pulse so the dot still reads "busy", just statically.
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.antgrid.accent;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, _) => Center(
          child: Container(
            width: widget.size * _scale.value,
            height: widget.size * _scale.value,
            decoration: BoxDecoration(
              color: color,
              borderRadius: AbTokens.borderRadius3,
            ),
          ),
        ),
      ),
    );
  }
}
