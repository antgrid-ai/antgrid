import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import 'loading.dart';

/// An on/off switch for a setting that applies immediately.
///
/// The toggle always shows exactly [value]. It never flips optimistically:
/// [onChanged] reports the requested value and the host decides whether and
/// when to pass it back, so a pending or failed save can never look
/// successful. While the host is persisting, set [busy] to show a spinner in
/// the handle and block further activation; focus stays on the control.
///
/// The label is part of the tap target, as upstream's `<label htmlFor>` is:
/// a tap on it toggles, and it shares one semantics node with the switch.
///
/// The state is never color alone: the handle position, a visible "On"/"Off"
/// word beside the switch (unless [hideStateText]) and the toggled semantics
/// flag all carry it.
class CarbonToggle extends StatelessWidget {
  const CarbonToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.labelText,
    this.semanticLabel,
    this.onText,
    this.offText,
    this.hideStateText = false,
    this.small = false,
    this.readOnly = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  });

  /// The current setting, owned by the host.
  final bool value;

  /// Requests the opposite value; null disables the toggle.
  final ValueChanged<bool>? onChanged;

  /// A custom label shown above the switch. With no [labelText] or
  /// [semanticLabel] it is also the accessible name.
  final Widget? label;

  /// A plain text label shown above the switch; also the accessible name.
  final String? labelText;

  /// Accessible name when no label is shown.
  final String? semanticLabel;

  /// State words beside the switch; default to the localized "On" and "Off".
  final String? onText;
  final String? offText;

  /// Hides the state word; the switch itself and semantics still carry it.
  final bool hideStateText;

  /// Carbon's 32x16 track instead of 48x24.
  final bool small;

  /// Focusable and announced, but cannot change.
  final bool readOnly;

  /// The host is applying a change: shows a spinner and blocks activation.
  final bool busy;

  final FocusNode? focusNode;
  final bool autofocus;

  static void _ignore() {}

  /// Carbon puts 16px between the label and the switch (toggle.scss:29-34).
  /// The track is centred in a taller target, so the label's own padding is
  /// what is left once that slack is counted.
  double _labelGap(CarbonThemeData theme) {
    final slack = (theme.minTarget - (small ? 16 : 24)) / 2;
    return math.max(0, CarbonSpacing.spacing05 - slack);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final loc = CarbonLocalizations.of(context);
    final enabled = onChanged != null;
    final name = labelText ?? semanticLabel;
    final stateWord = value ? (onText ?? loc.on) : (offText ?? loc.off);
    final inert = readOnly || busy;

    final Widget? labelWidget = label != null
        ? DefaultTextStyle.merge(
            style: theme.typography.label.copyWith(
              color: enabled ? colors.textSecondary : colors.textDisabled,
            ),
            child: label!,
          )
        : (labelText != null
              ? Text(
                  labelText!,
                  style: theme.typography.label.copyWith(
                    color: enabled ? colors.textSecondary : colors.textDisabled,
                  ),
                )
              : null);

    final row = CarbonInteraction(
      onPressed: enabled
          ? (inert ? _ignore : () => onChanged!(!value))
          : null,
      focusNode: focusNode,
      autofocus: autofocus,
      button: false,
      label: name,
      value: busy ? loc.loading : null,
      toggled: value,
      // A custom label that is the only name must stay in the node; any
      // other label would be read twice.
      excludeChildSemantics: name != null || label == null,
      mouseCursor: inert ? SystemMouseCursors.basic : null,
      builder: (context, state, _) {
        final track = _ToggleTrack(
          value: value,
          small: small,
          enabled: enabled,
          readOnly: readOnly,
          busy: busy,
        );
        // One Column shape whether or not a label is shown keeps the
        // control's focus node and state across a label appearing.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (labelWidget != null)
              Padding(
                padding: EdgeInsetsDirectional.only(
                  bottom: _labelGap(theme),
                ),
                child: labelWidget,
              ),
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: theme.minTarget,
                minHeight: theme.minTarget,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CarbonFocusRing(
                    // :active draws the outline under pointer use too
                    // (toggle.scss:84).
                    visible: state.focusVisible || state.pressed,
                    borderRadius: BorderRadius.all(
                      small ? const Radius.circular(8) : CarbonShape.toggle,
                    ),
                    child: track,
                  ),
                  if (!hideStateText) ...[
                    const SizedBox(width: CarbonSpacing.spacing03),
                    Flexible(
                      // The state is already the toggled flag.
                      child: ExcludeSemantics(
                        child: Text(
                          stateWord,
                          style: theme.typography.control.copyWith(
                            color: enabled
                                ? colors.textPrimary
                                : colors.textDisabled,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );

    return MergeSemantics(
      child: Semantics(readOnly: readOnly ? true : null, child: row),
    );
  }
}

class _ToggleTrack extends StatelessWidget {
  const _ToggleTrack({
    required this.value,
    required this.small,
    required this.enabled,
    required this.readOnly,
    required this.busy,
  });

  final bool value;
  final bool small;
  final bool enabled;
  final bool readOnly;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    final width = small ? 32.0 : 48.0;
    final height = small ? 16.0 : 24.0;
    const inset = 3.0;
    final handle = height - inset * 2;

    final Color trackColor;
    final Color handleColor;
    Border? border;
    if (!enabled) {
      trackColor = colors.buttonDisabled;
      handleColor = colors.iconOnColorDisabled;
    } else if (readOnly) {
      trackColor = const Color(0x00000000);
      handleColor = colors.iconPrimary;
      border = Border.all(color: colors.iconDisabled);
    } else {
      trackColor = value ? colors.supportSuccess : colors.toggleOff;
      handleColor = colors.iconOnColor;
    }

    final duration = CarbonMotion.resolve(context, CarbonMotion.fast01);
    final radius = BorderRadius.all(Radius.circular(height / 2));
    final glyphSize = handle - 4;

    Widget? glyph;
    if (busy) {
      glyph = CarbonSpinner(
        size: handle - 2,
        color: colors.interactive,
        trackColor: const Color(0x00000000),
      );
    } else if (value && small && !readOnly) {
      glyph = CarbonIcon(
        CarbonIcons.checkmark,
        size: glyphSize,
        color: enabled ? colors.supportSuccess : colors.buttonDisabled,
      );
    } else if (value && readOnly) {
      glyph = CarbonIcon(
        CarbonIcons.checkmark,
        size: glyphSize,
        color: colors.iconInverse,
      );
    }

    return SizedBox(
      width: width,
      height: height,
      child: AnimatedContainer(
        duration: duration,
        curve: CarbonMotion.exit,
        decoration: BoxDecoration(color: trackColor, borderRadius: radius),
        // Drawn over the track rather than as part of it, which would pad the
        // handle in by the border width and squash it.
        foregroundDecoration: border == null
            ? null
            : BoxDecoration(borderRadius: radius, border: border),
        child: Padding(
          padding: const EdgeInsets.all(inset),
          child: AnimatedAlign(
            duration: duration,
            curve: CarbonMotion.exit,
            alignment: value
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            child: SizedBox.square(
              dimension: handle,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: handleColor,
                  shape: BoxShape.circle,
                ),
                child: glyph == null ? null : Center(child: glyph),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
