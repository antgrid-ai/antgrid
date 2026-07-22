import 'package:flutter/widgets.dart';

import '../../design/ab_tokens.dart';
import '../../design/ab_colors.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/agent_event.dart';

/// Orders permission options by kind so the "safe" action (allow once) always
/// leads and the destructive one (reject) always trails, regardless of the
/// order the agent sent them in.
const Map<String, int> _kindOrder = {
  'allow_once': 0,
  'allow_always': 1,
  'reject': 2,
};

/// Always-visible panel pinned above the composer that surfaces the single
/// oldest pending permission or question. Permissions/questions are
/// transport-level asks, not transcript content, so they get their own fixed
/// slot here instead of scrolling away as inline rows.
class PendingPromptPanel extends StatefulWidget {
  final List<AgentPermissionRequest> permissions;
  final List<AgentQuestion> questions;
  final void Function(AgentPermissionRequest request, String optionId)
  onPermission;
  final void Function(AgentQuestion question, Object answer) onQuestion;

  /// Focus node for the text-question field, owned by the parent so a
  /// chronological prompt marker can pull focus here on tap.
  final FocusNode? inputFocusNode;

  const PendingPromptPanel({
    super.key,
    required this.permissions,
    required this.questions,
    required this.onPermission,
    required this.onQuestion,
    this.inputFocusNode,
  });

  @override
  State<PendingPromptPanel> createState() => _PendingPromptPanelState();
}

class _PendingPromptPanelState extends State<PendingPromptPanel> {
  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, Set<String>> _multiSelectPicks = {};

  @override
  void didUpdateWidget(PendingPromptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Drop per-question bookkeeping once a question is resolved or retracted
    // (no longer in the pending list). Otherwise every question ever asked
    // leaves an undisposed TextEditingController behind for the panel's life.
    final live = {for (final q in widget.questions) q.questionId};
    _textControllers.removeWhere((id, controller) {
      if (live.contains(id)) return false;
      controller.dispose();
      return true;
    });
    _multiSelectPicks.removeWhere((id, _) => !live.contains(id));
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _textControllerFor(String questionId) =>
      _textControllers.putIfAbsent(questionId, TextEditingController.new);

  Set<String> _picksFor(String questionId) =>
      _multiSelectPicks.putIfAbsent(questionId, () => <String>{});

  @override
  Widget build(BuildContext context) {
    final prompts = <Object>[...widget.permissions, ...widget.questions];
    if (prompts.isEmpty) return const SizedBox.shrink();

    final c = context.antgrid;
    final first = prompts.first;

    return Container(
      decoration: BoxDecoration(
        color: c.bgElevated,
        border: Border(top: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.all(AbTokens.space8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                first is AgentPermissionRequest ? 'PERMISSION' : 'QUESTION',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXxs,
                  color: c.warning,
                ),
              ),
              const Spacer(),
              if (prompts.length > 1)
                Text(
                  '1 of ${prompts.length}',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXxs,
                    color: c.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AbTokens.space8),
          if (first is AgentPermissionRequest) _buildPermission(context, first),
          if (first is AgentQuestion) _buildQuestion(context, first),
        ],
      ),
    );
  }

  Widget _buildPermission(
    BuildContext context,
    AgentPermissionRequest request,
  ) {
    final c = context.antgrid;
    final options = [...request.options]
      ..sort(
        (a, b) =>
            (_kindOrder[a.kind] ?? 99).compareTo(_kindOrder[b.kind] ?? 99),
      );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          request.title,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: c.textPrimary,
          ),
        ),
        if (request.reason != null) ...[
          const SizedBox(height: AbTokens.space4),
          Text(
            request.reason!,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: c.textMuted,
            ),
          ),
        ],
        const SizedBox(height: AbTokens.space8),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space8,
          children: [
            for (final option in options)
              AbButton(
                label: option.label,
                variant: option.kind == 'allow_once'
                    ? AbButtonVariant.primary
                    : AbButtonVariant.normal,
                color: option.kind == 'reject' ? c.error : null,
                onTap: () => widget.onPermission(request, option.optionId),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuestion(BuildContext context, AgentQuestion question) {
    return switch (question.kind) {
      'single_select' => _buildSingleSelect(context, question),
      'multi_select' => _buildMultiSelect(context, question),
      _ => _buildTextQuestion(context, question),
    };
  }

  Widget _buildTextQuestion(BuildContext context, AgentQuestion question) {
    final c = context.antgrid;
    final controller = _textControllerFor(question.questionId);
    void submit() {
      final text = controller.text.trim();
      if (text.isEmpty) return;
      widget.onQuestion(question, text);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.prompt,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        Row(
          children: [
            Expanded(
              child: AbTextField(
                controller: controller,
                focusNode: widget.inputFocusNode,
                obscureText: question.isSecret,
                onSubmitted: (_) => submit(),
              ),
            ),
            const SizedBox(width: AbTokens.space4),
            AbButton(label: 'Answer', onTap: submit),
          ],
        ),
      ],
    );
  }

  Widget _buildSingleSelect(BuildContext context, AgentQuestion question) {
    final c = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.prompt,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space8,
          children: [
            for (final option in question.options)
              AbButton(
                label: option.label,
                onTap: () => widget.onQuestion(question, option.id),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMultiSelect(BuildContext context, AgentQuestion question) {
    final c = context.antgrid;
    final picks = _picksFor(question.questionId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.prompt,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space8,
          children: [
            for (final option in question.options)
              AbChip.toggle(
                label: option.label,
                selected: picks.contains(option.id),
                onTap: () => setState(() {
                  if (!picks.remove(option.id)) picks.add(option.id);
                }),
              ),
          ],
        ),
        const SizedBox(height: AbTokens.space8),
        Align(
          alignment: Alignment.centerRight,
          child: AbButton(
            label: 'Submit',
            onTap: () => widget.onQuestion(question, picks.toList()),
          ),
        ),
      ],
    );
  }
}
