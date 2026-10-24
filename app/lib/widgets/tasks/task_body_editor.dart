import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_control_box.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_scrollbar.dart';
import '../../design/widgets/ab_segmented.dart';
import '../../design/widgets/ab_separator.dart';
import '../transcript/markdown_body.dart';
import 'markdown_format.dart';

/// The task description editor: markdown source with a formatting toolbar and
/// a Write / Preview switch, laid out after GitHub's issue composer because
/// that is where these bodies go when a task is published.
///
/// Preview renders through [TranscriptMarkdown], the same renderer the task
/// detail view reads the saved body with, so what Preview shows is what the
/// task will show.
class TaskBodyEditor extends StatefulWidget {
  const TaskBodyEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = 'Describe the work. This becomes the agent’s brief.',
    this.minLines = 10,
    this.maxLines = 24,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final int minLines;
  final int maxLines;
  final bool autofocus;

  @override
  State<TaskBodyEditor> createState() => _TaskBodyEditorState();
}

class _TaskBodyEditorState extends State<TaskBodyEditor> {
  late FocusNode _focus;
  bool _ownsFocus = false;
  var _preview = false;
  final _previewScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _focus = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(TaskBodyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _focus.removeListener(_onFocus);
      if (_ownsFocus) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
      _ownsFocus = widget.focusNode == null;
      _focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (_ownsFocus) _focus.dispose();
    _previewScroll.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  void _apply(TextEditingValue Function(TextEditingValue) edit) {
    if (_preview) return;
    widget.controller.value = edit(widget.controller.value);
    _focus.requestFocus();
  }

  void _toggleTask(int index) {
    final next = MarkdownFormat.toggleTask(widget.controller.text, index);
    if (next == null) return;
    setState(() => widget.controller.text = next);
  }

  void _setPreview(bool preview) {
    setState(() => _preview = preview);
    if (!preview) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final style = AbTokens.sansStyle(fontSize: AbTokens.fontMd, height: 1.5);
    final lineHeight = AbTokens.fontMd * 1.5;
    final bodyMinHeight = widget.minLines * lineHeight;

    final tools =
        <(String, String, TextEditingValue Function(TextEditingValue))>[
          (
            AbIcons.mdHeading,
            'Heading',
            (v) => MarkdownFormat.linePrefix(v, '### '),
          ),
          (
            AbIcons.mdBold,
            'Bold (Ctrl+B)',
            (v) => MarkdownFormat.wrap(v, '**'),
          ),
          (
            AbIcons.mdItalic,
            'Italic (Ctrl+I)',
            (v) => MarkdownFormat.wrap(v, '_'),
          ),
          (
            AbIcons.mdStrikethrough,
            'Strikethrough',
            (v) => MarkdownFormat.wrap(v, '~~'),
          ),
          (AbIcons.mdQuote, 'Quote', (v) => MarkdownFormat.linePrefix(v, '> ')),
          (AbIcons.code, 'Code (Ctrl+E)', MarkdownFormat.code),
          (AbIcons.link, 'Link (Ctrl+K)', MarkdownFormat.link),
          (
            AbIcons.mdBulletList,
            'Bulleted list',
            (v) => MarkdownFormat.linePrefix(v, '- '),
          ),
          (
            AbIcons.mdNumberedList,
            'Numbered list',
            (v) => MarkdownFormat.linePrefix(v, '', numbered: true),
          ),
          (
            AbIcons.mdTaskList,
            'Task list',
            (v) => MarkdownFormat.linePrefix(v, '- [ ] '),
          ),
        ];

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space6,
        AbTokens.space6,
        AbTokens.space6,
        AbTokens.space6,
      ),
      child: Row(
        children: [
          AbSegmented<bool>(
            segments: const [
              AbSegment(value: false, label: 'Write'),
              AbSegment(value: true, label: 'Preview'),
            ],
            selected: _preview,
            onSelect: _setPreview,
          ),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            // Scrolls rather than wraps: a toolbar folding onto a second row
            // under a narrow sheet pushes the text down for no gain.
            child: Visibility(
              visible: !_preview,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    for (final (icon, tooltip, edit) in tools)
                      AbIconButton(
                        icon: icon,
                        tooltip: tooltip,
                        onTap: () => _apply(edit),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final Widget body;
    if (_preview) {
      final text = widget.controller.text;
      // Capped at the height Write's field stops growing at and scrolled
      // inside, so a long body never stretches the sheet around it and the
      // box keeps its size when switching between the two.
      const padding = AbTokens.space12 * 2;
      body = ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: bodyMinHeight + padding,
          maxHeight: widget.maxLines * lineHeight + padding,
        ),
        child: AbScrollbar(
          controller: _previewScroll,
          child: SingleChildScrollView(
            controller: _previewScroll,
            padding: const EdgeInsets.all(AbTokens.space12),
            child: text.trim().isEmpty
                ? Text(
                    'Nothing to preview',
                    style: style.copyWith(color: palette.textMuted),
                  )
                : TranscriptMarkdown(data: text, onToggleTask: _toggleTask),
          ),
        ),
      );
    } else {
      body = CallbackShortcuts(
        bindings: {
          for (final meta in [false, true]) ...{
            SingleActivator(
              LogicalKeyboardKey.keyB,
              control: !meta,
              meta: meta,
            ): () =>
                _apply((v) => MarkdownFormat.wrap(v, '**')),
            SingleActivator(
              LogicalKeyboardKey.keyI,
              control: !meta,
              meta: meta,
            ): () =>
                _apply((v) => MarkdownFormat.wrap(v, '_')),
            SingleActivator(
              LogicalKeyboardKey.keyE,
              control: !meta,
              meta: meta,
            ): () =>
                _apply(MarkdownFormat.code),
            SingleActivator(
              LogicalKeyboardKey.keyK,
              control: !meta,
              meta: meta,
            ): () =>
                _apply(MarkdownFormat.link),
          },
        },
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            autofocus: widget.autofocus,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            keyboardType: TextInputType.multiline,
            style: style,
            cursorColor: palette.accent,
            decoration: InputDecoration(
              isCollapsed: true,
              // AbControlBox owns fill and border — see AbMultilineField.
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              hintText: widget.hintText,
              hintStyle: style.copyWith(color: palette.textMuted),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }

    final footer = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      child: Row(
        children: [
          AbIcon(
            AbIcons.markdown,
            size: AbTokens.iconButtonGlyph,
            color: palette.textMuted,
          ),
          const SizedBox(width: AbTokens.space6),
          Text(
            'Markdown is supported',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
      ),
    );

    return AbControlBox(
      focused: _focus.hasFocus && !_preview,
      padding: EdgeInsets.zero,
      // A floor of nothing: the box grows with the editor instead of
      // clamping it to one control row.
      minHeight: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const AbSeparator.horizontal(),
          body,
          const AbSeparator.horizontal(),
          footer,
        ],
      ),
    );
  }
}
