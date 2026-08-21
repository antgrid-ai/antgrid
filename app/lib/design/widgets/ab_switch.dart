import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_focus_ring.dart';

/// Capsule toggle for a single on/off setting the user owns.
///
/// Deliberately NOT an [AbSegmented] with Off|On cells. A segmented control is
/// for picking among alternatives that deserve equal billing; a setting has a
/// default and a departure from it, and the knob's position says which side
/// you're on from across the room. Use the segmented control when the two
/// options are peers (a mode), this when one of them is "on".
///
/// The capsule is the one place the design system's 2px radius yields: the
/// shape IS the affordance here — a rectangular track with a sliding block
/// reads as a progress bar, not a switch — and it is the only pill-shaped
/// control besides the status pill.
///
/// Pass `onChanged: null` to disable (0.4 opacity, no hover, no focus stop),
/// per the design-system disabled-state contract.
class AbSwitch extends StatefulWidget {
  const AbSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.tone,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Fill of the ON track. Defaults to the accent. Pass a status color where
  /// the switch reports something live (a machine on the air) rather than a
  /// preference.
  final Color? tone;

  final String? semanticLabel;

  @override
  State<AbSwitch> createState() => _AbSwitchState();
}

/// Base geometry, scaled by the ambient text scaler so the control tracks the
/// type beside it (same contract as `AbIconButton`'s box).
const _trackW = 32.0;
const _trackH = 18.0;

/// Near-full track height on purpose. A small puck in a tall track reads as a
/// slider handle; the knob has to look like the thing that fills the groove.
const _knob = 14.0;
const _border = 1.0;

class _AbSwitchState extends State<AbSwitch> {
  bool _hovered = false;
  bool _focused = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final disabled = widget.onChanged == null;
    final on = widget.value;
    final tone = widget.tone ?? p.accent;

    final scaler = MediaQuery.textScalerOf(context);
    final trackW = scaler.scale(_trackW);
    final trackH = scaler.scale(_trackH);
    final knob = scaler.scale(_knob);
    final radius = BorderRadius.circular(trackH / 2);

    final Widget track = AnimatedContainer(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      width: trackW,
      height: trackH,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: on ? tone : p.bgDeepest,
        border: Border.all(
          width: _border,
          color: on
              ? tone
              : _hovered
              ? p.borderStrong
              : p.borderDefault,
        ),
      ),
      padding: EdgeInsets.all((trackH - knob) / 2 - _border),
      child: AnimatedAlign(
        duration: AbTokens.motionDefault,
        curve: Curves.easeOut,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: knob,
          height: knob,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Dark knob on a lit track: the fill is the signal, and a white
            // knob would compete with it for the eye.
            color: on
                ? p.bgDeepest
                : (_hovered ? p.textSecondary : p.textMuted),
          ),
        ),
      ),
    );

    if (disabled) {
      return Semantics(
        toggled: on,
        enabled: false,
        label: widget.semanticLabel,
        child: Opacity(opacity: 0.4, child: track),
      );
    }

    return Semantics(
      toggled: on,
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
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
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: _toggle,
          behavior: HitTestBehavior.opaque,
          child: AbFocusRing(
            focused: _focused,
            borderRadius: radius,
            child: track,
          ),
        ),
      ),
    );
  }
}
