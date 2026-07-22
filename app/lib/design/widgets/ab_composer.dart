import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';

class AbComposer extends StatefulWidget {
  const AbComposer({
    super.key,
    required this.agentTag,
    required this.attachments,
    required this.onSend,
    required this.onRemoveAttachment,
    this.placeholder = 'Ask the agent…',
  });

  final String agentTag;
  final List<String> attachments;
  final void Function(String) onSend;
  final void Function(int index) onRemoveAttachment;
  final String placeholder;

  @override
  State<AbComposer> createState() => _AbComposerState();
}

class _AbComposerState extends State<AbComposer> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text;
    if (text.isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final focused = _focus.hasFocus;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: AbTokens.borderRadius8,
        border: Border.all(color: focused ? p.borderStrong : p.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '@${widget.agentTag}',
                style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.statusThinking),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  maxLines: null,
                  minLines: 2,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontMd,
                    color: p.textPrimary,
                    height: 1.5,
                  ),
                  cursorColor: p.accent,
                  cursorWidth: 7,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    hintText: widget.placeholder,
                    hintStyle: TextStyle(color: p.textDisabled, fontSize: AbTokens.fontMd),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.borderSubtle)),
            ),
            child: Row(
              children: [
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < widget.attachments.length; i++)
                      _Chip(
                        label: '+ ${widget.attachments[i]}',
                        onRemove: () => widget.onRemoveAttachment(i),
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  '${widget.attachments.length} file${widget.attachments.length == 1 ? '' : 's'}',
                  style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
                ),
                const SizedBox(width: 8),
                _SendButton(onTap: _submit),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onRemove});
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: p.bgRaised,
        border: Border.all(color: p.borderDefault),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
          ),
          const SizedBox(width: 5),
          GestureDetector(
            onTap: onRemove,
            child: AbIcon(AbIcons.close, size: 10, color: p.textDisabled),
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.accent,
          borderRadius: AbTokens.borderRadius5,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Send',
              style: TextStyle(
                fontSize: AbTokens.fontSm,
                fontWeight: FontWeight.w500,
                color: p.accentForeground,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '⌘↵',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.accentForeground.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
