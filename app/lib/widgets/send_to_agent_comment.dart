import 'dart:async';
import 'dart:math' as math;

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
///
/// [anchorLink] pins the popover under whatever triggered it (typically a
/// `CompositedTransformTarget` around a "Send to Agent" button) instead of
/// the window centre — so the box appears where the user was just looking,
/// beside the selection it's about. Desktop/tablet only: the mobile bottom
/// sheet is already anchored to the action by sliding up from the bottom of
/// the same screen, so it ignores this.
Future<String?> showSendToAgentComment({
  required BuildContext context,
  required String selectedText,
  required String sourceLabel,
  Uint8List? imageBytes,
  LayerLink? anchorLink,
}) async {
  final screenWidth = MediaQuery.of(context).size.width;
  final isMobile = screenWidth < kCompactBreakpoint;

  if (isMobile) {
    return _showBottomSheet(context, selectedText, sourceLabel, imageBytes);
  } else {
    return _showPopover(
      context,
      selectedText,
      sourceLabel,
      imageBytes,
      anchorLink,
    );
  }
}

void showSentToAgentSnackBar(BuildContext context) {
  showAbSnackBar(
    context,
    'Sent to agent',
    duration: const Duration(milliseconds: 1500),
  );
}

/// Counterpart to [showSentToAgentSnackBar] for a send the transport refused.
///
/// Nothing was buffered, so this is the user's only notice that the text they
/// captured is gone — every surface that hands text to the agent's terminal
/// owes the same sentence, or the same failure reads differently depending on
/// where it happened.
void showSendRefusedSnackBar(BuildContext context) {
  showAbSnackBar(context, "couldn't send — the session is reconnecting");
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

/// Anchored under [anchorLink] when one is given — hanging the box off the
/// button that triggered it, top-right of the terminal, rather than dropping
/// it in the window's centre where nothing else on screen points to it. Falls
/// back to centred when there's no link (a caller with no fixed trigger
/// widget to hang off).
///
/// Growth is leftward and downward from the button's bottom-right corner —
/// the button lives at the panel's trailing edge, so leftward is the only
/// direction that stays inside it, same reasoning as `WorkspaceMenuButton`'s
/// popup. [_clampedPopoverWidth] is what keeps that leftward box from
/// overrunning the left edge on a narrow panel.
Future<String?> _showPopover(
  BuildContext context,
  String selectedText,
  String sourceLabel,
  Uint8List? imageBytes,
  LayerLink? anchorLink,
) async {
  final overlay = Overlay.of(context);
  final completer = Completer<String?>();
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      final width = _clampedPopoverWidth(size.width);
      final surface = Material(
        color: const Color(0x00000000),
        child: Container(
          width: width,
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
      );
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
          anchorLink == null
              ? Center(child: surface)
              : CompositedTransformFollower(
                  link: anchorLink,
                  targetAnchor: Alignment.bottomRight,
                  followerAnchor: Alignment.topRight,
                  offset: const Offset(0, AbTokens.space8),
                  // The follower otherwise hangs off the RIGHT edge of its
                  // target with no bound — off the button is off the window
                  // too, since the button itself sits at the panel's own
                  // trailing edge.
                  child: Align(alignment: Alignment.topRight, child: surface),
                ),
        ],
      );
    },
  );

  overlay.insert(entry);
  return completer.future;
}

/// [_kPopoverWidth], but never wider than the window can show with a margin
/// on both sides — the anchored placement grows leftward off a button
/// pinned to the right edge, so an unclamped width is what would otherwise
/// run past the LEFT edge on a narrow panel (a docked context pane, a
/// tablet split) that the centred placement never had to worry about.
double _clampedPopoverWidth(double screenWidth) =>
    math.min(_kPopoverWidth, screenWidth - AbTokens.space16 * 2);

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
