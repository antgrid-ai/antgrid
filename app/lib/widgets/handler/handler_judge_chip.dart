import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/agent_event.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/capability_catalog.dart';
import '../../util/detached.dart';
import '../new_session/context_picker.dart';
import 'handler_session_settings.dart';

/// Radio value for "no override": [CarbonMenuRadioGroup] never reports the
/// option that is already selected, so the default needs a real value rather
/// than null to be pickable and to show its check.
const String _defaultValue = '';

/// The judge, beside the box that types the sentence it will read.
///
/// The judge belongs in a composer's control row and not only in a settings
/// block because it is what actually READS the typed instruction: the bridge
/// splits a sentence into backlog items only when the judge can run headless,
/// and hands the whole sentence over as one item otherwise. Naming it here is
/// naming who is about to read this.
///
/// The trigger names the judge and, when one is overridden, the model that
/// qualifies it; a model never stands alone.
class HandlerJudgeChip extends ConsumerWidget {
  const HandlerJudgeChip({
    super.key,
    required this.terminalId,
    required this.judge,
    required this.onChanged,
    required this.scopeNote,
    this.enabled = true,
  });

  final String terminalId;
  final HandlerJudgePick judge;
  final ValueChanged<HandlerJudgePick> onChanged;

  /// When the pick takes effect, in the host's own terms — see
  /// [handlerJudgeScopeOnArm] and [handlerJudgeScopeNextPass]. The chip cannot
  /// derive it: the same control means "from the moment it arms" on one surface
  /// and "on the next pass" on the other.
  final String scopeNote;

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(agentCatalogProvider);
    // The chip names what will actually run rather than the word "Default": the
    // pick and the inherited default are told apart by the check mark in the
    // menu, which is the one place that question is being asked.
    final effective = handlerEffectiveJudge(ref, terminalId, judge.judgeTool);
    final defaultTool = handlerEffectiveJudge(ref, terminalId, null);
    // Read unconditionally, even with no model override and no menu open:
    // the first read of a key kicks off an async load and answers empty, so a
    // catalog first touched when the menu opens would show the "nobody has
    // listed these" branch and swap it for a list a frame later. Starting here
    // means the answer is already settled by the time it shows.
    final models = effective == null
        ? const <AgentCapabilityModel>[]
        : cachedModelsFor(ref, effective);
    final judgeTools = ref.watch(judgeCapableToolsProvider);

    String judgeLabel(String? tool) =>
        tool == null ? 'Default' : (catalog[tool]?.label ?? tool);
    final effectiveLabel = effective == null ? 'Judge' : judgeLabel(effective);
    final modelLabel = _modelLabel(models, judge.judgeModel);

    // A judge change takes the model with it: a model id is a name only its
    // own CLI answers to, so carried across it becomes a flag the new judge
    // rejects on every pass. Re-picking the judge already in force never
    // reaches here (the group does not report it), which matters because the
    // delta would read `judgeModel: null` as "clear it".
    void pickJudge(String picked) => onChanged((
      judgeTool: picked == _defaultValue ? null : picked,
      judgeModel: null,
    ));

    void pickModel(String? id) =>
        onChanged((judgeTool: judge.judgeTool, judgeModel: id));

    void typeModelId() {
      detached('HandlerJudgeChip', 'type a model id', () async {
        final typed = await showCarbonModal<String>(
          context,
          builder: (_) => _ModelIdModal(
            initial: judge.judgeModel ?? '',
            hint: models.isEmpty
                ? "This machine hasn't heard $effectiveLabel list its models — "
                      'type an id.'
                : null,
          ),
        );
        if (typed == null) return;
        pickModel(typed.isEmpty ? null : typed);
      });
    }

    final currentModelLabel = judge.judgeModel == null
        ? 'Default'
        : (modelLabel ?? judge.judgeModel!);

    return ContextPicker(
      icon: CarbonIcons.security,
      label: modelLabel == null
          ? effectiveLabel
          : '$effectiveLabel · $modelLabel',
      field: 'Judge',
      enabled: enabled,
      entries: [
        CarbonMenuRadioGroup<String>(
          label: 'Judged by',
          value: judge.judgeTool ?? _defaultValue,
          options: [
            CarbonOption(
              value: _defaultValue,
              label: defaultTool == null
                  ? 'Default'
                  : 'Default (${judgeLabel(defaultTool)})',
            ),
            for (final tool in judgeTools)
              CarbonOption(value: tool, label: judgeLabel(tool)),
          ],
          onChanged: pickJudge,
        ),
        const CarbonMenuDivider(),
        // A submenu even for a three-model agent: one agent exposes twenty-odd,
        // and a menu that changes shape per agent is one the user relearns per
        // agent.
        if (models.isEmpty)
          CarbonMenuItem(
            label: 'Model: $currentModelLabel — type an id…',
            icon: const CarbonIcon(CarbonIcons.code),
            onPressed: effective == null ? null : typeModelId,
          )
        else
          CarbonMenuSubmenu(
            label: 'Model',
            icon: const CarbonIcon(CarbonIcons.code),
            entries: [
              CarbonMenuRadioGroup<String>(
                value: judge.judgeModel ?? _defaultValue,
                options: [
                  const CarbonOption(value: _defaultValue, label: 'Default'),
                  for (final m in models)
                    CarbonOption(value: m.id, label: m.name),
                ],
                onChanged: (id) => pickModel(id == _defaultValue ? null : id),
              ),
              const CarbonMenuDivider(),
              CarbonMenuItem(label: 'Type a model id…', onPressed: typeModelId),
            ],
          ),
        const CarbonMenuDivider(),
        CarbonMenuGroup(label: scopeNote, children: const []),
      ],
    );
  }

  /// The model's display name, or null when nothing is overridden — a trigger
  /// with no model half is the default, which needs no word of its own.
  ///
  /// Falls back to the raw id: a model typed by hand is never in the catalog,
  /// and showing it back is the only confirmation the user gets that it stuck.
  String? _modelLabel(List<AgentCapabilityModel> models, String? id) {
    if (id == null) return null;
    final matches = models.where((m) => m.id == id);
    return matches.isEmpty ? id : matches.first.name;
  }
}

/// Free-text model id, for a model no catalog lists. Pops the trimmed id, or
/// an empty string for "no override".
class _ModelIdModal extends StatefulWidget {
  const _ModelIdModal({required this.initial, this.hint});

  final String initial;
  final String? hint;

  @override
  State<_ModelIdModal> createState() => _ModelIdModalState();
}

class _ModelIdModalState extends State<_ModelIdModal> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Committed on submit or the button, not per keystroke: each change is a
  // configure frame, and a half-typed model id is one the judge would try to
  // run.
  void _commit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return CarbonModal(
      title: 'Model id',
      size: CarbonModalSize.xs,
      body: CarbonTextInput(
        controller: _controller,
        label: 'Model id',
        placeholder: 'Model id',
        helperText: widget.hint ?? 'Leave empty for the default model.',
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _commit(),
      ),
      actions: [
        CarbonModalAction(
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CarbonModalAction(label: 'Set model', onPressed: _commit),
      ],
    );
  }
}
