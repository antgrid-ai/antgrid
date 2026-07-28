import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_snack_bar.dart';

import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';

/// Returns the formatted message string, or null if cancelled.
Future<String?> showSendToAgentComment({
  required BuildContext context,
  required String selectedText,
  required String sourceLabel,
  Rect? anchorRect,
}) async {
  final screenWidth = MediaQuery.of(context).size.width;
  final isMobile = screenWidth < kCompactBreakpoint;

  if (isMobile) {
    return _showBottomSheet(context, selectedText, sourceLabel);
  } else {
    return _showPopover(context, selectedText, sourceLabel, anchorRect);
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
        onSend: (message) => Navigator.of(context).pop(message),
        onCancel: () => Navigator.of(context).pop(null),
      ),
    ),
  );
}

Future<String?> _showPopover(
  BuildContext context,
  String selectedText,
  String sourceLabel,
  Rect? anchorRect,
) async {
  final overlay = Overlay.of(context);
  final completer = Completer<String?>();
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) {
      final top = anchorRect != null ? anchorRect.bottom + 4 : 48.0;
      final right = anchorRect != null
          ? MediaQuery.of(context).size.width - anchorRect.right
          : 8.0;

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
          Positioned(
            top: top,
            right: right,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 300,
                decoration: BoxDecoration(
                  color: context.antgrid.bgSurface,
                  border: Border.all(color: context.antgrid.borderDefault),
                  borderRadius: AbTokens.borderRadius8,
                ),
                child: _CommentContent(
                  selectedText: selectedText,
                  sourceLabel: sourceLabel,
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

class _CommentContent extends StatefulWidget {
  final String selectedText;
  final String sourceLabel;
  final ValueChanged<String> onSend;
  final VoidCallback onCancel;

  const _CommentContent({
    required this.selectedText,
    required this.sourceLabel,
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

    return Padding(
      padding: const EdgeInsets.all(AbTokens.space16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.sourceLabel,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space8),
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
                onTap: widget.onCancel,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AbTokens.space8,
                      vertical: AbTokens.space4,
                    ),
                    child: Text(
                      'Cancel',
                      style: AbTokens.sansStyle(color: context.antgrid.textMuted),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AbTokens.space8),
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
                          style: AbTokens.sansStyle(color: context.antgrid.accent),
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
