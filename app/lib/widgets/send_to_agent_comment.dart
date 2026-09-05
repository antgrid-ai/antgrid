import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_snack_bar.dart';

import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';

/// Returns the formatted message string, or null if cancelled.
///
/// [imageBytes], when given, is shown as a thumbnail above the text preview —
/// the capture routes (an element pick, a drawing over the preview) attach a
/// picture the user never otherwise sees before it reaches the agent, and a
/// crop of the wrong element is only obvious when you can look at it.
Future<String?> showSendToAgentComment({
  required BuildContext context,
  required String selectedText,
  required String sourceLabel,
  Uint8List? imageBytes,
}) async {
  final screenWidth = MediaQuery.of(context).size.width;
  final isMobile = screenWidth < kCompactBreakpoint;

  if (isMobile) {
    return _showBottomSheet(context, selectedText, sourceLabel, imageBytes);
  } else {
    return _showPopover(context, selectedText, sourceLabel, imageBytes);
  }
}

void showSentToAgentSnackBar(BuildContext context) {
  showAbSnackBar(
    context,
    'Sent to agent',
    duration: const Duration(milliseconds: 1500),
  );
}

Future<String?> _showBottomSheet(
  BuildContext context,
  String selectedText,
  String sourceLabel,
  Uint8List? imageBytes,
) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.antgrid.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
    ),
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _CommentContent(
        selectedText: selectedText,
        sourceLabel: sourceLabel,
        imageBytes: imageBytes,
        onSend: (message) => Navigator.of(context).pop(message),
        onCancel: () => Navigator.of(context).pop(null),
      ),
    ),
  );
}

/// Centred, not anchored to whatever triggered it.
///
/// This box is a modal step in the middle of a flow — read the capture, type a
/// line, send — and the thing it is about (a picked element, a drawing) is
/// already highlighted on the page behind it. Hanging it off a toolbar button
/// put it in a corner, over the top-right of the very preview the user is
/// being asked to look at, and pushed it off screen entirely on a narrow
/// panel. The centre is where a modal is looked for.
Future<String?> _showPopover(
  BuildContext context,
  String selectedText,
  String sourceLabel,
  Uint8List? imageBytes,
) async {
  final overlay = Overlay.of(context);
  final completer = Completer<String?>();
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      return Stack(
        children: [
          GestureDetector(
            onTap: () {
              entry.remove();
              if (!completer.isCompleted) completer.complete(null);
            },
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
          Center(
            child: Material(
              color: const Color(0x00000000),
              child: Container(
                width: _kPopoverWidth,
                // Never taller than the window it floats in — a large capture
                // preview would otherwise push the comment field and the Send
                // button off the bottom.
                constraints: BoxConstraints(maxHeight: size.height * 0.8),
                decoration: BoxDecoration(
                  color: context.antgrid.bgSurface,
                  border: Border.all(color: context.antgrid.borderDefault),
                  borderRadius: AbTokens.borderRadius8,
                ),
                child: _CommentContent(
                  selectedText: selectedText,
                  sourceLabel: sourceLabel,
                  imageBytes: imageBytes,
                  onSend: (message) {
                    entry.remove();
                    if (!completer.isCompleted) completer.complete(message);
                  },
                  onCancel: () {
                    entry.remove();
                    if (!completer.isCompleted) completer.complete(null);
                  },
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  overlay.insert(entry);
  return completer.future;
}

const double _kPopoverWidth = 480.0;

/// Default ceiling on [CaptureImagePreview]. Tall enough to recognise a
/// cropped element or a drawing without squinting, short enough that the
/// comment field stays in view without scrolling for the common case.
const double _kCapturePreviewMaxHeight = 380.0;

class _CommentContent extends StatefulWidget {
  final String selectedText;
  final String sourceLabel;
  final Uint8List? imageBytes;
  final ValueChanged<String> onSend;
  final VoidCallback onCancel;

  const _CommentContent({
    required this.selectedText,
    required this.sourceLabel,
    required this.imageBytes,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<_CommentContent> createState() => _CommentContentState();
}

class _CommentContentState extends State<_CommentContent> {
  final _commentController = TextEditingController();
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onCancel();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isShiftPressed) {
          _send();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _commentController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final comment = _commentController.text.trim();
    final buffer = StringBuffer();
    if (comment.isNotEmpty) {
      buffer.writeln(comment);
    }
    buffer.writeln(widget.sourceLabel);
    buffer.write(widget.selectedText);
    widget.onSend(buffer.toString());
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.selectedText.length > 200
        ? '${widget.selectedText.substring(0, 200)}...'
        : widget.selectedText;
    final previewLines = preview.split('\n');
    final truncatedPreview = previewLines.length > 3
        ? '${previewLines.take(3).join('\n')}...'
        : preview;

    final image = widget.imageBytes;
    return Padding(
      padding: const EdgeInsets.all(AbTokens.space16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  widget.sourceLabel,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    color: context.antgrid.textMuted,
                  ),
                ),
              ),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Cancel',
                onTap: widget.onCancel,
              ),
            ],
          ),
          const SizedBox(height: AbTokens.space8),
          if (image != null) ...[
            CaptureImagePreview(bytes: image),
            const SizedBox(height: AbTokens.space8),
          ],
          Container(
            padding: const EdgeInsets.all(AbTokens.space8),
            decoration: BoxDecoration(
              color: context.antgrid.bgDeepest,
              borderRadius: AbTokens.borderRadius3,
              border: Border.all(color: context.antgrid.borderSubtle),
            ),
            child: Text(
              truncatedPreview,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                height: 1.3,
                color: context.antgrid.textSecondary,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: AbTokens.space12),
          TextField(
            controller: _commentController,
            focusNode: _focusNode,
            minLines: 2,
            maxLines: 2,
            style: AbTokens.sansStyle(fontSize: AbTokens.fontMd),
            decoration: InputDecoration(
              hintText: 'Add a comment (optional)',
              hintStyle: AbTokens.sansStyle(
                fontSize: AbTokens.fontMd,
                color: context.antgrid.textMuted,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space12,
                vertical: AbTokens.space10,
              ),
              border: OutlineInputBorder(
                borderRadius: AbTokens.borderRadius5,
                borderSide: BorderSide(color: context.antgrid.borderDefault),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AbTokens.borderRadius5,
                borderSide: BorderSide(color: context.antgrid.borderDefault),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: AbTokens.borderRadius5,
                borderSide: BorderSide(color: context.antgrid.accent),
              ),
              filled: true,
              fillColor: context.antgrid.bgDeepest,
            ),
          ),
          const SizedBox(height: AbTokens.space12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: _send,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AbTokens.space12,
                      vertical: AbTokens.space6,
                    ),
                    decoration: BoxDecoration(
                      color: context.antgrid.bgElevated,
                      border: Border.all(color: context.antgrid.borderDefault),
                      borderRadius: AbTokens.borderRadius5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AbIcon(
                          AbIcons.send,
                          size: 12,
                          color: context.antgrid.accent,
                        ),
                        const SizedBox(width: AbTokens.space4),
                        Text(
                          'Send',
                          style: AbTokens.sansStyle(
                            color: context.antgrid.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The exact image about to be attached, shown before it is. Shared by the
/// comment popover above and by `showAutoSendCapture` (the draw tool's
/// auto-send dialog), so both surfaces show the pending capture at the same
/// size.
///
/// Decoded at [_kCaptureDecodeWidth] rather than natively: a viewport capture
/// is a multi-megapixel bitmap, and holding one at full size to draw it a
/// couple of hundred pixels wide is the difference between a thumbnail and a
/// spike in memory every time this box opens.
class CaptureImagePreview extends StatelessWidget {
  const CaptureImagePreview({
    super.key,
    required this.bytes,
    this.maxHeight = _kCapturePreviewMaxHeight,
  });

  static const int _kCaptureDecodeWidth = 960;

  final Uint8List bytes;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.antgrid.bgDeepest,
          borderRadius: AbTokens.borderRadius3,
          border: Border.all(color: context.antgrid.borderSubtle),
        ),
        child: ClipRRect(
          borderRadius: AbTokens.borderRadius3,
          child: Image.memory(
            bytes,
            cacheWidth: _kCaptureDecodeWidth,
            fit: BoxFit.contain,
            // A capture that somehow won't decode must not take the whole
            // send flow down with it — the text half of the message is still
            // worth sending.
            errorBuilder: (context, _, _) => Padding(
              padding: const EdgeInsets.all(AbTokens.space8),
              child: Text(
                'Preview unavailable',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
