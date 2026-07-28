import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_separator.dart';
import 'terminal_upload_button.dart';

/// The touch-input helper bar shown under the terminal on devices without a
/// physical keyboard (mobile/remote). A horizontally-scrolling strip of upload
/// + control-key shortcuts, with a large Keyboard toggle pinned to the right
/// corner (thumb-reachable, key-sized).
///
/// All dependencies are plain callbacks so the bar renders without a session,
/// a picker, or the Ghostty engine (see the golden test).
class TerminalQuickActionsBar extends StatelessWidget {
  const TerminalQuickActionsBar({
    super.key,
    required this.softKeyboardController,
    required this.onPick,
    required this.onUpload,
    required this.onInsertPath,
    required this.onUploadError,
    required this.onSendInput,
  });

  final GhosttyTerminalSoftKeyboardController softKeyboardController;
  final Future<PickedUpload?> Function() onPick;
  final Future<String> Function(String fileName, Uint8List bytes) onUpload;
  final void Function(String path) onInsertPath;
  final void Function(String message) onUploadError;
  final void Function(String data) onSendInput;

  @override
  Widget build(BuildContext context) {
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
                    upload: onUpload,
                    // Double-quoted + trailing space: paste-a-path semantics
                    // identical to desktop drag-drop; quotes survive spaces in
                    // both PowerShell and POSIX shells.
                    onInsertPath: onInsertPath,
                    onError: onUploadError,
                  ),
                  _actionButton(context, 'Tab', '\t'),
                  _actionButton(context, 'Esc', '\x1b'),
                  _actionButton(context, 'Ctrl+C', '\x03'),
                  _actionButton(context, 'Ctrl+D', '\x04'),
                  _actionButton(context, '↑', '\x1b[A'),
                  _actionButton(context, '↓', '\x1b[B'),
                  _actionButton(context, '→', '\x1b[C'),
                  _actionButton(context, '←', '\x1b[D'),
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
          // Taps no longer summon the IME (showKeyboardOnInteraction false), so
          // this is the one way in — `toggle` also dismisses it on a 2nd press.
          _KeyboardToggleButton(controller: softKeyboardController),
        ],
      ),
    );
  }

  Widget _actionButton(BuildContext context, String label, String data) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSendInput(data),
        child: Container(
          height: AbTokens.rowHeightXl,
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.bgSurface,
            borderRadius: AbTokens.borderRadius5,
            border: Border.all(color: p.borderDefault),
          ),
          child: Text(
            label,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontLg,
              color: p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The pinned keyboard control: the keyboard glyph plus a SINGLE state-driven
/// arrowhead — an up-chevron ABOVE it while the keyboard is closed (tap to
/// raise), a down-chevron BELOW it while it is open (tap to dismiss). Only one
/// arrowhead shows at a time, so the glyph always points the way the tap moves
/// the keyboard.
///
/// Stateful + [WidgetsBindingObserver] so it rebuilds on every IME show/hide —
/// including a system Back-button dismiss, which changes the window insets
/// without routing through [GhosttyTerminalSoftKeyboardController.toggle].
class _KeyboardToggleButton extends StatefulWidget {
  const _KeyboardToggleButton({required this.controller});

  final GhosttyTerminalSoftKeyboardController controller;

  @override
  State<_KeyboardToggleButton> createState() => _KeyboardToggleButtonState();
}

class _KeyboardToggleButtonState extends State<_KeyboardToggleButton>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // Keyboard show/hide changes the bottom view inset — rebuild so the
    // arrowhead follows the new state (a Back-button dismiss lands here too).
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Window bottom inset (keyboard height) is the primary signal — robust
    // regardless of Scaffold resize handling; fall back to the view's live IME
    // state so a system dismiss the insets haven't caught up to still flips.
    final keyboardUp =
        MediaQuery.viewInsetsOf(context).bottom > 0 ||
        widget.controller.isVisible;
    final color = context.antgrid.textSecondary;
    final keyboard = AbIcon(
      AbIcons.keyboard,
      size: AbTokens.iconButtonGlyphXl,
      color: color,
    );
    final chevron = AbIcon(
      keyboardUp ? AbIcons.chevronDown : AbIcons.chevronUp,
      size: AbTokens.space10,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.only(left: AbTokens.space2),
      child: Tooltip(
        message: keyboardUp ? 'Hide keyboard' : 'Show keyboard',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.controller.toggle,
          child: SizedBox(
            width: AbTokens.rowHeightXl,
            height: AbTokens.rowHeightXl,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              // Chevron sits above the keyboard when closed (points up/raise),
              // below it when open (points down/dismiss).
              children: keyboardUp
                  ? [keyboard, chevron]
                  : [chevron, keyboard],
            ),
          ),
        ),
      ),
    );
  }
}
