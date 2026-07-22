import 'package:flutter/material.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_control_box.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_menu.dart';
import '../../models/handler_state.dart';

class HandlerConfigChoice {
  final bool enabled;
  final HandlerTemplate template;
  final String? model;
  const HandlerConfigChoice({
    required this.enabled,
    required this.template,
    required this.model,
  });
}

class _ModelPreset {
  final String label;
  // null = Default (bridge picks a per-tool cheap model in buildJudgeCommand)
  final String? value;
  const _ModelPreset(this.label, this.value);
}

const kHandlerJudgeModels = <_ModelPreset>[
  _ModelPreset('Default (recommended)', null),
  _ModelPreset('Haiku (fast)', 'claude-haiku-4-5'),
  _ModelPreset('Sonnet (balanced)', 'claude-sonnet-4-6'),
];

// showAbMenu<String> returns null on dismiss, which collides with the
// null-valued "Default" preset. Map Default to this sentinel in the menu and
// back on selection so a dismiss is distinguishable from picking Default.
const _kDefaultModelSentinel = '__handler_default_model__';

String _modelLabel(String? value) => kHandlerJudgeModels
    .firstWhere(
      (m) => m.value == value,
      orElse: () => kHandlerJudgeModels.first,
    )
    .label;

const _templateBlurbs = <HandlerTemplate, String>{
  HandlerTemplate.watchdog: 'Notify only. Never touches the agent or code.',
  HandlerTemplate.closer:
      'Answers when confident; escalates when unsure or risky.',
  HandlerTemplate.autopilot:
      'Answers aggressively; escalates only hard blockers.',
};

const _templateTitles = <HandlerTemplate, String>{
  HandlerTemplate.watchdog: 'Watchdog',
  HandlerTemplate.closer: 'Closer',
  HandlerTemplate.autopilot: 'Autopilot',
};

Future<HandlerConfigChoice?> showHandlerEnableSheet(
  BuildContext context, {
  required bool enabled,
  required HandlerTemplate template,
  String? model,
}) {
  return showAbAdaptiveSheet<HandlerConfigChoice>(
    context,
    maxWidth: 420,
    child: _HandlerEnableForm(
      initialEnabled: enabled,
      initialTemplate: template,
      initialModel: model,
    ),
  );
}

class _HandlerEnableForm extends StatefulWidget {
  const _HandlerEnableForm({
    required this.initialEnabled,
    required this.initialTemplate,
    required this.initialModel,
  });

  final bool initialEnabled;
  final HandlerTemplate initialTemplate;
  final String? initialModel;

  @override
  State<_HandlerEnableForm> createState() => _HandlerEnableFormState();
}

class _HandlerEnableFormState extends State<_HandlerEnableForm> {
  late bool _enabled = widget.initialEnabled;
  late HandlerTemplate _template = widget.initialTemplate;
  late String? _model = widget.initialModel;

  Future<void> _openModelMenu(BuildContext anchorCtx) async {
    final anchorRect = abMenuAnchorRect(anchorCtx);
    if (anchorRect == null) return;
    final picked = await showAbMenu<String>(
      context: anchorCtx,
      anchorRect: anchorRect,
      width: anchorRect.width,
      entries: [
        for (final m in kHandlerJudgeModels)
          AbMenuItem(
            label: m.label,
            value: m.value ?? _kDefaultModelSentinel,
            icon: m.value == _model ? AbIcons.check : null,
          ),
      ],
    );
    if (picked == null) return; // dismissed
    if (!mounted) return; // sheet dismissed during the menu's async gap
    setState(() => _model = picked == _kDefaultModelSentinel ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            'Handler',
            onClose: () => Navigator.pop(context),
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        for (final t in HandlerTemplate.values)
          AbListRow(
            title: Text(
              _templateTitles[t]!,
              style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _templateBlurbs[t]!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textMuted,
              ),
            ),
            selected: _template == t,
            selectionStyle: AbRowSelection.accentBar,
            onTap: () => setState(() => _template = t),
          ),
        const SizedBox(height: AbTokens.space12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space16),
          child: Row(
            children: [
              Text(
                'Judge model',
                style: AbTokens.sansStyle(color: p.textSecondary),
              ),
              const SizedBox(width: AbTokens.space12),
              Expanded(
                child: Builder(
                  builder: (anchorCtx) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openModelMenu(anchorCtx),
                      child: AbControlBox(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _modelLabel(_model),
                                overflow: TextOverflow.ellipsis,
                                style: AbTokens.sansStyle(color: p.textPrimary),
                              ),
                            ),
                            const SizedBox(width: AbTokens.space6),
                            AbIcon(
                              AbIcons.chevronDown,
                              size: 12,
                              color: p.textMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space16),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _enabled = !_enabled),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    // Design-system checkbox built from primitives: a bordered
                    // box filled with the accent color when on, holding an
                    // AbIcon check. The Antgrid system has no checkbox widget
                    // and raw Icons.* is banned, so this must be hand-built.
                    Container(
                      width: 18,
                      height: 18,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _enabled ? p.accent : Colors.transparent,
                        borderRadius: AbTokens.borderRadius,
                        border: Border.all(
                          color: _enabled ? p.accent : p.borderStrong,
                        ),
                      ),
                      child: _enabled
                          ? AbIcon(
                              AbIcons.check,
                              size: 12,
                              color: p.accentForeground,
                            )
                          : null,
                    ),
                    const SizedBox(width: AbTokens.space8),
                    Text(
                      'Enable Handler',
                      style: AbTokens.sansStyle(color: p.textPrimary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            0,
            AbTokens.space16,
            AbTokens.space16,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(label: 'Cancel', onTap: () => Navigator.pop(context)),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: 'Save',
                variant: AbButtonVariant.primary,
                onTap: () => Navigator.pop(
                  context,
                  HandlerConfigChoice(
                    enabled: _enabled,
                    template: _template,
                    model: _model,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
