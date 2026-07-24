import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

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

/// "Upload" entry for the terminal quick-actions bar (mobile/web). Picks a
/// file, streams it to the bridge's staging dir, then hands the returned
/// absolute path to [onInsertPath] — the terminal-mode analogue of desktop
/// drag-drop, which pastes a path.
///
/// All dependencies are injected so the widget is testable without a picker,
/// a session, or the Ghostty engine.
class TerminalUploadButton extends StatefulWidget {
  const TerminalUploadButton({
    super.key,
    required this.pick,
    required this.upload,
    required this.onInsertPath,
    required this.onError,
  });

  final Future<PickedUpload?> Function() pick;
  final Future<String> Function(String fileName, Uint8List bytes) upload;
  final void Function(String path) onInsertPath;
  final void Function(String message) onError;

  @override
  State<TerminalUploadButton> createState() => _TerminalUploadButtonState();
}

class _TerminalUploadButtonState extends State<TerminalUploadButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    PickedUpload? picked;
    try {
      picked = await widget.pick();
    } on UploadException catch (e) {
      // e.g. TOO_LARGE rejected by the picker before reading the file.
      widget.onError(uploadErrorText(e, e.message));
      return;
    } catch (_) {
      widget.onError('Could not open the file picker');
      return;
    }
    if (picked == null) return;
    if (picked.bytes.length > UploadService.kMaxUploadBytes) {
      widget.onError(
        uploadErrorText(const UploadException('TOO_LARGE', ''), picked.name),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final path = await widget.upload(picked.name, picked.bytes);
      if (!mounted) return;
      widget.onInsertPath(path);
    } catch (e) {
      widget.onError(uploadErrorText(e, picked.name));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mirrors the keyboard icon button in terminal_view_wrapper.dart so the
    // bar reads as one row of uniform controls. AbIconButton renders its
    // disabled state itself (onTap null → 0.4 opacity) while busy.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
      child: SizedBox(
        height: AbTokens.rowHeightXl,
        child: Center(
          child: AbIconButton(
            icon: AbIcons.attach,
            tooltip: _busy ? 'Uploading…' : 'Attach file',
            onTap: _busy ? null : _run,
            boxSize: AbTokens.rowHeightXl,
            glyphSize: AbTokens.iconButtonGlyphXl,
          ),
        ),
      ),
    );
  }
}
