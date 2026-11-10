import 'dart:async';

import 'package:flutter/widgets.dart';

/// A bounded-rate breathing animation shared by small activity indicators.
class PulseBuilder extends StatelessWidget {
  const PulseBuilder({
    super.key,
    required this.builder,
    this.child,
    this.halfCycle = const Duration(milliseconds: 900),
    this.restingValue = 1,
  }) : assert(restingValue >= 0 && restingValue <= 1);

  final ValueWidgetBuilder<double> builder;
  final Widget? child;
  final Duration halfCycle;
  final double restingValue;

  static final _clock = _PulseClock();

  @override
  Widget build(BuildContext context) {
    assert(halfCycle > Duration.zero);
    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    // Scale and color changes must not repaint a surrounding row or workspace.
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: animate
            ? _clock
            : const AlwaysStoppedAnimation(Duration.zero),
        builder: (context, elapsed, child) {
          final phase = animate
              ? (elapsed.inMicroseconds % (halfCycle.inMicroseconds * 2)) /
                    halfCycle.inMicroseconds
              : restingValue;
          final value = phase <= 1 ? phase : 2 - phase;
          return builder(context, Curves.easeInOut.transform(value), child);
        },
        child: child,
      ),
    );
  }
}

// Even a tiny glyph schedules a window-wide raster frame. One low-frequency
// clock bounds that cost across different pulse durations and staggered mounts.
class _PulseClock extends ValueNotifier<Duration> with WidgetsBindingObserver {
  _PulseClock() : super(Duration.zero);

  static const _interval = Duration(milliseconds: 100);
  Timer? _timer;

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) {
      WidgetsBinding.instance.addObserver(this);
      _syncTimer(WidgetsBinding.instance.lifecycleState);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _stopTimer();
      WidgetsBinding.instance.removeObserver(this);
      value = Duration.zero;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncTimer(state);

  void _syncTimer(AppLifecycleState? state) {
    final visible = switch (state) {
      null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      _ => false,
    };
    if (!visible) {
      _stopTimer();
      return;
    }
    _timer ??= Timer.periodic(_interval, (timer) {
      value = _interval * timer.tick;
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
