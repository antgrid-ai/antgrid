import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../services/upload_service.dart';

class PickedUpload {
  final String name;
  final Uint8List bytes;
  const PickedUpload({required this.name, required this.bytes});
}

/// Opens the platform file picker and reads the selection into memory.
/// Null when the user cancels. Throws [UploadException] `TOO_LARGE` when the
/// file's stat length exceeds the cap, so an oversized pick is rejected before
/// it's read into memory (readAsBytes would otherwise buffer the whole file).
Future<PickedUpload?> pickUploadFile() async {
  final file = await openFile();
  if (file == null) return null;
  try {
    if (await file.length() > UploadService.kMaxUploadBytes) {
      throw UploadException('TOO_LARGE', file.name);
    }
  } on UploadException {
    rethrow;
  } catch (_) {
    // length() unsupported on this platform — fall through to the byte check.
  }
  return PickedUpload(name: file.name, bytes: await file.readAsBytes());
}

/// Runs the pick step and hands the result to [onPicked]. Never throws — a
/// picker failure is reported through [onError] — so both attach affordances
/// share one interpretation of a cancelled, oversized or unavailable picker.
Future<void> runFilePick({
  required Future<PickedUpload?> Function() pick,
  required Future<void> Function(PickedUpload picked) onPicked,
  required void Function(String message) onError,
}) async {
  PickedUpload? picked;
  try {
    picked = await pick();
  } on UploadException catch (e) {
    // e.g. TOO_LARGE rejected by the picker before reading the file; the
    // exception's message carries the name the picker reported.
    onError(uploadErrorText(e, e.message));
    return;
  } catch (_) {
    onError('Could not open the file picker');
    return;
  }
  if (picked == null) return;
  try {
    await onPicked(picked);
  } catch (error) {
    // Both call sites start this from a VoidCallback, which discards the
    // future — an escaping rejection would reach PlatformDispatcher.onError as
    // a fatal instead of the message the user is owed.
    onError(uploadErrorText(error, picked.name));
  }
}

/// "Upload" entry for the terminal quick-actions bar (mobile/web). Picks a
/// file and hands it to [onPicked], which uploads it and types the returned
/// host path — the terminal-mode analogue of desktop drag-drop.
///
/// [busy] comes from the shared attachment pipeline rather than local state, so
/// a paste or drop already in flight disables this button too.
///
/// All dependencies are injected so the widget is testable without a picker,
/// a session, or the Ghostty engine.
class TerminalUploadButton extends StatefulWidget {
  const TerminalUploadButton({
    super.key,
    required this.pick,
    required this.onPicked,
    required this.busy,
    required this.onError,
  });

  final Future<PickedUpload?> Function() pick;
  final Future<void> Function(PickedUpload picked) onPicked;
  final bool busy;
  final void Function(String message) onError;

  @override
  State<TerminalUploadButton> createState() => _TerminalUploadButtonState();
}

class _TerminalUploadButtonState extends State<TerminalUploadButton> {
  /// The picker is open before anything reaches the shared pipeline, so
  /// [TerminalUploadButton.busy] cannot cover this window on its own.
  bool _picking = false;

  Future<void> _run() async {
    if (_picking || widget.busy) return;
    setState(() => _picking = true);
    try {
      await runFilePick(
        pick: widget.pick,
        onPicked: widget.onPicked,
        onError: widget.onError,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mirrors the keyboard icon button in terminal_view_wrapper.dart so the
    // bar reads as one row of uniform controls. AbIconButton renders its
    // disabled state itself (onTap null → 0.4 opacity) while busy.
    final busy = _picking || widget.busy;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
      child: SizedBox(
        height: AbTokens.rowHeightXl,
        child: Center(
          child: AbIconButton(
            icon: AbIcons.attach,
            tooltip: busy ? 'Uploading…' : 'Attach file',
            onTap: busy ? null : _run,
            boxSize: AbTokens.rowHeightXl,
            glyphSize: AbTokens.iconButtonGlyphXl,
          ),
        ),
      ),
    );
  }
}

/// The desktop attach affordance: a compact floating pill for the terminal's
/// overlay stack.
///
/// Desktop gets this instead of the quick-actions bar because the rest of that
/// bar (zoom steps, control keys, the IME toggle) exists only for a device with
/// no physical keyboard, while attaching is the one thing a desktop driving a
/// REMOTE agent cannot otherwise do — its clipboard and its files live on the
/// wrong machine.
class TerminalAttachOverlayButton extends StatefulWidget {
  const TerminalAttachOverlayButton({
    super.key,
    required this.pick,
    required this.onPicked,
    required this.busy,
    required this.onError,
  });

  final Future<PickedUpload?> Function() pick;
  final Future<void> Function(PickedUpload picked) onPicked;
  final bool busy;
  final void Function(String message) onError;

  @override
  State<TerminalAttachOverlayButton> createState() =>
      _TerminalAttachOverlayButtonState();
}

class _TerminalAttachOverlayButtonState
    extends State<TerminalAttachOverlayButton> {
  bool _picking = false;

  Future<void> _run() async {
    if (_picking || widget.busy) return;
    setState(() => _picking = true);
    try {
      await runFilePick(
        pick: widget.pick,
        onPicked: widget.onPicked,
        onError: widget.onError,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final busy = _picking || widget.busy;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgElevated,
        borderRadius: AbTokens.borderRadius5,
        border: Border.all(color: p.accent.withValues(alpha: 0.3)),
      ),
      child: AbIconButton(
        icon: AbIcons.attach,
        tooltip: busy ? 'Uploading…' : 'Attach a file for the agent',
        onTap: busy ? null : _run,
        color: p.accent,
      ),
    );
  }
}
