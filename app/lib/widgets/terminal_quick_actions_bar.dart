import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_separator.dart';
import 'pane_swipe_exclusion.dart';
import 'terminal_modifier_keys.dart';
import 'terminal_upload_button.dart';

/// The touch-input helper bar shown under the terminal on devices without a
/// physical keyboard (mobile/remote). A horizontally-scrolling strip of upload
/// + control-key shortcuts, with a large Keyboard toggle pinned to the right
/// corner (thumb-reachable, key-sized) that opens and closes the prompt box,
/// and on a long press raises the raw soft keyboard onto the terminal instead.
///
/// All dependencies are plain callbacks so the bar renders without a session,
/// a picker, or the Ghostty engine (see the golden test).
class TerminalQuickActionsBar extends StatelessWidget {
  const TerminalQuickActionsBar({
    super.key,
    required this.onPick,
    required this.onPicked,
    required this.uploadBusy,
    required this.onUploadError,
    required this.onSendInput,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onZoomReset,
    this.voiceControl,
    required this.modifiers,
    required this.onToggleModifier,
    required this.composeOpen,
    required this.onToggleCompose,
    required this.onDirectInput,
  });

  /// Sticky Ctrl/Alt/Shift, armed here and spent by the next keystroke from
  /// this bar or the soft keyboard (see [TerminalModifierLatch]).
  final ValueListenable<TerminalModifiers> modifiers;
  final void Function(TerminalModifierKey key) onToggleModifier;

  /// Whether the prompt box is up. The keyboard key opens it — typing goes to
  /// the box and reaches the terminal on Send, never key by key — and closes it.
  final bool composeOpen;
  final VoidCallback onToggleCompose;

  /// Long press on the keyboard key: the raw soft keyboard on the terminal,
  /// key by key. The prompt box always submits, and terminal taps never raise
  /// the IME, so without this a phone has no way to send one keystroke — no
  /// letter for an armed Ctrl or Alt to land on, no tab completion, no
  /// single-key TUI.
  final VoidCallback onDirectInput;
  final Future<PickedUpload?> Function() onPick;
  final Future<void> Function(PickedUpload picked) onPicked;

  /// True while the shared attachment pipeline is busy with ANY gesture, so a
  /// paste or drop already in flight disables the bar's attach key too.
  final bool uploadBusy;
  final void Function(String message) onUploadError;
  final void Function(String data) onSendInput;

  /// Terminal text-size steps. [onZoomReset] is bound to long-press on either
  /// zoom key — pinch-zoom has no discoverable way back to 1.0.
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomReset;
  final Widget? voiceControl;

  @override
  Widget build(BuildContext context) {
    // The key strip scrolls sideways; a swipe along it must not also open the
    // sidebar the way a swipe over the terminal above it does.
    return PaneSwipeExclusion(child: _buildBar(context));
  }

  Widget _buildBar(BuildContext context) {
    return Container(
      color: context.antgrid.bgElevated,
      padding: const EdgeInsets.symmetric(
        vertical: AbTokens.space4,
        horizontal: AbTokens.space4,
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  TerminalUploadButton(
                    pick: onPick,
                    onPicked: onPicked,
                    busy: uploadBusy,
                    onError: onUploadError,
                  ),
                  _actionButton(context, 'Esc', '\x1b'),
                  _actionButton(context, 'Tab', '\t'),
                  ValueListenableBuilder<TerminalModifiers>(
                    valueListenable: modifiers,
                    builder: (context, m, _) => Row(
                      children: [
                        _modifierButton(
                          context,
                          'Ctrl',
                          TerminalModifierKey.ctrl,
                          m.ctrl,
                        ),
                        _modifierButton(
                          context,
                          'Alt',
                          TerminalModifierKey.alt,
                          m.alt,
                        ),
                        _modifierButton(
                          context,
                          'Shift',
                          TerminalModifierKey.shift,
                          m.shift,
                        ),
                      ],
                    ),
                  ),
                  _key(
                    context,
                    icon: AbIcons.enterKey,
                    semanticLabel: 'Enter',
                    onTap: () => onSendInput('\r'),
                  ),
                  _actionButton(context, '↑', '\x1b[A'),
                  _actionButton(context, '↓', '\x1b[B'),
                  _actionButton(context, '←', '\x1b[D'),
                  _actionButton(context, '→', '\x1b[C'),
                  _zoomButton(
                    context,
                    icon: AbIcons.zoomOut,
                    semanticLabel: 'Decrease terminal text size',
                    onTap: onZoomOut,
                  ),
                  _zoomButton(
                    context,
                    icon: AbIcons.zoomIn,
                    semanticLabel: 'Increase terminal text size',
                    onTap: onZoomIn,
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AbTokens.space2),
            child: SizedBox(
              height: AbTokens.rowHeightXl,
              child: AbSeparator.vertical(),
            ),
          ),
          // Pinned trailing control in the right corner (thumb-reachable),
          // kept OUT of the horizontal scroll so it never slides off-screen.
          // Terminal taps never summon the IME (showKeyboardOnInteraction
          // false), so this key is the one way in: a tap for the prompt box,
          // a long press for the raw keyboard.
          ?voiceControl,
          _KeyboardToggleButton(
            open: composeOpen,
            onTap: onToggleCompose,
            onLongPress: onDirectInput,
          ),
        ],
      ),
    );
  }

  /// Zoom key. Same shell as [_actionButton] so the strip reads as one row of
  /// keys, but carries a glyph plus a long-press reset.
  Widget _zoomButton(
    BuildContext context, {
    required String icon,
    required String semanticLabel,
    required VoidCallback onTap,
  }) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
      child: Semantics(
        label: semanticLabel,
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onZoomReset,
          child: Container(
            height: AbTokens.rowHeightXl,
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.bgSurface,
              borderRadius: AbTokens.borderRadius5,
              border: Border.all(color: p.borderDefault),
            ),
            child: AbIcon(icon, size: AbTokens.fontLg, color: p.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _actionButton(
    BuildContext context,
    String label,
    String data, {
    String? semanticLabel,
  }) => _key(
    context,
    label: label,
    semanticLabel: semanticLabel,
    onTap: () => onSendInput(data),
  );

  Widget _modifierButton(
    BuildContext context,
    String label,
    TerminalModifierKey key,
    bool armed,
  ) => Semantics(
    toggled: armed,
    child: _key(
      context,
      label: label,
      armed: armed,
      onTap: () => onToggleModifier(key),
    ),
  );

  /// One key of the strip: a [label], or an [icon] for a key whose symbol the
  /// mono font lacks (its fallback glyph drew at a different size).
  Widget _key(
    BuildContext context, {
    String? label,
    String? icon,
    required VoidCallback onTap,
    String? semanticLabel,
    bool armed = false,
  }) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
      child: Semantics(
        label: semanticLabel,
        button: true,
        excludeSemantics: semanticLabel != null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: AbTokens.rowHeightXl,
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space10),
            alignment: Alignment.center,
            // Armed wears the primary button's pair: accent-on-accentMuted all
            // but vanished on the slate theme, and a latched key has to be
            // unmistakable before the next keystroke spends it.
            decoration: BoxDecoration(
              color: armed ? p.accent : p.bgSurface,
              borderRadius: AbTokens.borderRadius5,
              border: Border.all(color: armed ? p.accent : p.borderDefault),
            ),
            child: icon != null
                ? AbIcon(icon, size: AbTokens.fontLg, color: p.textSecondary)
                : Text(
                    label ?? '',
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontLg,
                      color: armed ? p.accentForeground : p.textSecondary,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The pinned keyboard control: the keyboard glyph plus a SINGLE state-driven
/// arrowhead — an up-chevron ABOVE it while the prompt box is closed (tap to
/// raise), a down-chevron BELOW it while it is open (tap to dismiss). Only one
/// arrowhead shows at a time, so the glyph always points the way the tap moves
/// the box. A long press bypasses the box and raises the raw keyboard.
class _KeyboardToggleButton extends StatelessWidget {
  const _KeyboardToggleButton({
    required this.open,
    required this.onTap,
    required this.onLongPress,
  });

  final bool open;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final color = context.antgrid.textSecondary;
    final keyboard = AbIcon(
      AbIcons.keyboard,
      size: AbTokens.iconButtonGlyphXl,
      color: color,
    );
    final chevron = AbIcon(
      open ? AbIcons.chevronDown : AbIcons.chevronUp,
      size: AbTokens.space10,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.only(left: AbTokens.space2),
      child: Tooltip(
        message: open ? 'Hide keyboard' : 'Show keyboard',
        // The tooltip's own long-press trigger would race the one below for
        // the pointer; this bar only mounts on touch, where hover never shows
        // it anyway, so the message is left as the key's accessible name.
        triggerMode: TooltipTriggerMode.manual,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            width: AbTokens.rowHeightXl,
            height: AbTokens.rowHeightXl,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              // Chevron sits above the keyboard when closed (points up/raise),
              // below it when open (points down/dismiss).
              children: open ? [keyboard, chevron] : [chevron, keyboard],
            ),
          ),
        ),
      ),
    );
  }
}
