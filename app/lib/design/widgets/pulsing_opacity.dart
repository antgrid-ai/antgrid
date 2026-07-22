import 'package:flutter/widgets.dart';

/// Repeats a 0.45 → 1.0 opacity pulse so a glyph can convey "running" without
/// fully disappearing. 900ms cycle, easeInOut.
class PulsingOpacity extends StatefulWidget {
  final Widget child;
  const PulsingOpacity({super.key, required this.child});

  @override
  State<PulsingOpacity> createState() => _PulsingOpacityState();
}

class _PulsingOpacityState extends State<PulsingOpacity>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        return Opacity(opacity: 0.45 + 0.55 * t, child: child);
      },
      child: widget.child,
    );
  }
}
