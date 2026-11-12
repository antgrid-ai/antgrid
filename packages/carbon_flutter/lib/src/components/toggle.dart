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

  /// A custom label shown above the switch.
  final Widget? label;

  /// A plain text label shown above the switch; also the accessible name.
  final String? labelText;

  /// Accessible name when no label is shown.
  final String? semanticLabel;

  /// State words beside the switch. Defaults to English until the library's
  /// localized strings carry them.
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

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final loc = CarbonLocalizations.of(context);
    final enabled = onChanged != null;
    final name = labelText ?? semanticLabel;
    final stateWord = value ? (onText ?? 'On') : (offText ?? 'Off');
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

    final control = CarbonInteraction(
      onPressed: enabled
          ? (inert ? _ignore : () => onChanged!(!value))
          : null,
      focusNode: focusNode,
      autofocus: autofocus,
      button: false,
      label: name,
      value: busy ? loc.loading : null,
      toggled: value,
      excludeChildSemantics: true,
      mouseCursor: inert ? SystemMouseCursors.basic : null,
      builder: (context, state, _) {
        final track = _ToggleTrack(
          value: value,
          small: small,
          enabled: enabled,
          readOnly: readOnly,
          busy: busy,
        );
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: theme.minTarget),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CarbonFocusRing(
                visible: state.focusVisible,
                borderRadius: BorderRadius.all(
                  small ? const Radius.circular(8) : CarbonShape.toggle,
                ),
                child: track,
              ),
              if (!hideStateText) ...[
                const SizedBox(width: CarbonSpacing.spacing03),
                Flexible(
                  child: Text(
                    stateWord,
                    style: theme.typography.body.copyWith(
                      color: enabled ? colors.textPrimary : colors.textDisabled,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );

    final target = MergeSemantics(child: control);
    if (labelWidget == null) return target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              bottom: CarbonSpacing.spacing02,
            ),
            child: labelWidget,
          ),
        ),
        target,
      ],
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
      trackColor = colors.borderDisabled;
      handleColor = colors.iconOnColor;
    } else if (readOnly) {
      trackColor = const Color(0x00000000);
      handleColor = colors.iconPrimary;
      border = Border.all(color: colors.iconPrimary);
    } else {
      trackColor = value ? colors.supportSuccess : colors.toggleOff;
      handleColor = colors.iconOnColor;
    }

    final duration = CarbonMotion.resolve(
      context,
      small ? CarbonMotion.fast01 : CarbonMotion.fast02,
    );
    final radius = BorderRadius.all(Radius.circular(height / 2));
    final glyphSize = handle - 4;

    Widget? glyph;
    if (busy) {
      glyph = CarbonSpinner(
        size: handle - 2,
        color: colors.interactive,
        trackColor: const Color(0x00000000),
      );
    } else if (value && !small && !readOnly) {
      glyph = CarbonIcon(
        CarbonIcons.checkmark,
        size: glyphSize,
        color: colors.supportSuccess,
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: radius,
          border: border,
        ),
        child: Padding(
          padding: const EdgeInsets.all(inset),
          child: AnimatedAlign(
            duration: duration,
            curve: CarbonMotion.standard,
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
