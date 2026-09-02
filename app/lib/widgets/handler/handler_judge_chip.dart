import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/agent_descriptor.dart';
import '../../models/agent_event.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/capability_catalog.dart';
import '../../util/detached.dart';
import '../new_session/environment_menu.dart';
import 'handler_session_settings.dart';

/// The judge, beside the box that types the sentence it will read.
///
/// The judge belongs in a composer's control row and not only in a settings
/// block because it is what actually READS the typed instruction: the bridge
/// splits a sentence into backlog items only when the judge can run headless,
/// and hands the whole sentence over as one item otherwise. Naming it here is
/// naming who is about to read this.
///
/// Compound label — judge, then model — because the model qualifies the judge
/// and never stands alone; [ComposerChip.secondaryLabel] is what makes the
/// model half shed first under width pressure while the judge name survives.
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
    // panel, which is the one place that question is being asked.
    final effective = handlerEffectiveJudge(ref, terminalId, judge.judgeTool);
    // Read unconditionally, even with no model override and no panel open:
    // the first read of a key kicks off an async load and answers empty, so a
    // catalog first touched at the drill would open the model pane on the
    // "nobody has listed these" branch and swap it for a list a frame later.
    // Starting here means the answer is already settled by the time it shows.
    final models = _modelsFor(ref, effective);
    return ComposerChip(
      icon: AbIcons.shield,
      label: effective == null
          ? 'Judge'
          : (catalog[effective]?.label ?? effective),
      secondaryLabel: _modelLabel(models, judge.judgeModel),
      enabled: enabled,
      onTap: (ctx) {
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        detached('HandlerJudgeChip', 'open judge panel', () async {
          await showAbPanel<void>(
            context: ctx,
            anchorRect: anchor,
            // The composer sits low on its surface, so the panel opens upward
            // — and stays pinned to the chip as the model pane grows.
            preferred: AbMenuPlacement.above,
            builder: (_) => _JudgePanel(
              terminalId: terminalId,
              initial: judge,
              scopeNote: scopeNote,
              onChanged: onChanged,
            ),
          );
        });
      },
    );
  }

  /// The model's display name, or null when nothing is overridden — a chip with
  /// no secondary half is the default, which needs no word of its own.
  ///
  /// Falls back to the raw id: a model typed by hand into the free-text branch
  /// is never in the catalog, and showing it back is the only confirmation the
  /// user gets that it stuck.
  String? _modelLabel(List<AgentCapabilityModel> models, String? id) {
    if (id == null) return null;
    final matches = models.where((m) => m.id == id);
    return matches.isEmpty ? id : matches.first.name;
  }
}

/// The judge's models, or empty when there is no judge to ask about.
///
/// Shared by the chip and its panel so both start hydration from their own
/// build — the panel needs its own call because pane one can change the judge,
/// and the drill that follows must not be the first touch of the new key.
List<AgentCapabilityModel> _modelsFor(WidgetRef ref, String? tool) =>
    tool == null
    ? const <AgentCapabilityModel>[]
    : cachedModelsFor(ref, tool);

/// One route, two panes. The model ALWAYS drills, even for a tool with three
/// models: one agent exposes twenty-odd, and a panel that changes shape per
/// agent is one the user relearns per agent.
class _JudgePanel extends ConsumerStatefulWidget {
  const _JudgePanel({
    required this.terminalId,
    required this.initial,
    required this.scopeNote,
    required this.onChanged,
  });

  final String terminalId;
  final HandlerJudgePick initial;
  final String scopeNote;
  final ValueChanged<HandlerJudgePick> onChanged;

  @override
  ConsumerState<_JudgePanel> createState() => _JudgePanelState();
}

class _JudgePanelState extends ConsumerState<_JudgePanel> {
  late HandlerJudgePick _pick;
  late final TextEditingController _search;
  late final TextEditingController _freeText;

  /// One node for both pane-two fields — only ever one of them is mounted, and
  /// sharing it keeps [_enterModelPane]'s focus request from having to know
  /// which branch it landed on.
  late final FocusNode _searchFocus;

  bool _drilled = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _pick = widget.initial;
    _search = TextEditingController()..addListener(_onQueryChanged);
    _freeText = TextEditingController(text: widget.initial.judgeModel ?? '');
    _searchFocus = FocusNode();
  }

  @override
  void dispose() {
    _search.removeListener(_onQueryChanged);
    _search.dispose();
    _freeText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() => _query = _search.text);

  /// Stays open on a judge pick: the panel's other half is the model, and a
  /// judge change is exactly when the model most needs revisiting.
  void _pickJudge(String? tool) {
    // The free-text field IS the model for a tool with no catalog, so it is
    // cleared with the value it holds — otherwise the new judge is offered the
    // previous CLI's id back, which is a flag it rejects on every pass.
    _freeText.clear();
    _search.clear();
    setState(() => _pick = (judgeTool: tool, judgeModel: null));
    widget.onChanged(_pick);
  }

  /// Pops: the model is the leaf of this panel, so committing it finishes the
  /// errand the chip was tapped for.
  void _pickModel(String? id) {
    setState(() => _pick = (judgeTool: _pick.judgeTool, judgeModel: id));
    widget.onChanged(_pick);
    Navigator.of(context).pop();
  }

  void _enterModelPane() {
    setState(() => _drilled = true);
    // autofocus fires once per FocusNode, at its first attach — a node this
    // State owns survives a back-and-re-drill, so the second visit would come
    // up unfocused with no error. The field is not attached yet when setState
    // runs, hence the post-frame request rather than a direct one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  String _judgeLabel(Map<String, AgentDescriptor> catalog, String? tool) =>
      tool == null ? 'Default' : (catalog[tool]?.label ?? tool);

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(agentCatalogProvider);
    final effective = handlerEffectiveJudge(
      ref,
      widget.terminalId,
      _pick.judgeTool,
    );
    // Read from pane one as well as pane two: picking a judge here changes the
    // key, and the drill that follows must not be the first touch of it.
    final models = _modelsFor(ref, effective);
    // AbPopupSurface.width is a MAX, not a fixed width, so a narrow first pane
    // followed by a wide second one visibly jumps. One SizedBox above the pane
    // switch pins both.
    return SizedBox(
      width: 280,
      child: _drilled
          ? _modelPane(catalog, effective, models)
          : _judgePane(catalog, effective, models),
    );
  }

  Widget _judgePane(
    Map<String, AgentDescriptor> catalog,
    String? effective,
    List<AgentCapabilityModel> models,
  ) {
    final p = context.antgrid;
    final defaultTool = handlerEffectiveJudge(ref, widget.terminalId, null);
    final judgeTools = ref.watch(judgeCapableToolsProvider);
    final modelName = _pick.judgeModel == null
        ? 'Default'
        : _modelName(models, _pick.judgeModel!);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Judged by'),
        PanelRow(
          icon: AbIcons.shield,
          label: defaultTool == null
              ? 'Default'
              : 'Default (${catalog[defaultTool]?.label ?? defaultTool})',
          selected: _pick.judgeTool == null,
          onTap: () => _pickJudge(null),
        ),
        for (final tool in judgeTools)
          PanelRow(
            icon: AbIcons.shield,
            label: catalog[tool]?.label ?? tool,
            selected: _pick.judgeTool == tool,
            onTap: () => _pickJudge(tool),
          ),
        // A drill row, not an inline list: see the class doc.
        PanelRow(
          icon: AbIcons.code,
          label: 'Model',
          selected: false,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Bounded: a model id can be longer than the panel is wide, and
              // PanelRow's trailing slot takes its intrinsic width.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontSm,
                    color: p.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: AbTokens.space6),
              AbIcon(AbIcons.chevronRight, size: 12, color: p.textMuted),
            ],
          ),
          onTap: _enterModelPane,
        ),
        PanelHint(widget.scopeNote),
      ],
    );
  }

  Widget _modelPane(
    Map<String, AgentDescriptor> catalog,
    String? effective,
    List<AgentCapabilityModel> models,
  ) {
    // Escape is bound at the route and pops the whole panel. Rebinding it on
    // this subtree makes the innermost enabled handler win, so Escape here goes
    // BACK — the typed query survives a mis-drill.
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            setState(() => _drilled = false);
            return null;
          },
        ),
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelRow(
            icon: AbIcons.back,
            // Names the judge it returns to, not the word "back": the pane
            // above is a judge list, and the model only means anything under one.
            label: _judgeLabel(catalog, effective),
            selected: false,
            // setState, never Navigator.pop: there is one route here, and a pop
            // would dismiss the whole panel along with the user's query.
            onTap: () => setState(() => _drilled = false),
          ),
          const PanelSectionHeader('Model'),
          // Pinned ABOVE the filter and outside the searched list: putting the
          // model back must never require clearing a query first.
          PanelRow(
            icon: AbIcons.code,
            label: 'Default',
            selected: _pick.judgeModel == null,
            onTap: () => _pickModel(null),
          ),
          if (models.isEmpty)
            ..._freeTextBranch(_judgeLabel(catalog, effective))
          else
            ..._modelListBranch(models),
        ],
      ),
    );
  }

  /// No catalog is not a broken path: the models list is written by a CHAT
  /// session of that tool, so a machine that has only ever run this agent in a
  /// terminal has nothing to offer and typing the id is the only way to name a
  /// model at all.
  List<Widget> _freeTextBranch(String judgeLabel) => [
    Padding(
      padding: const EdgeInsets.all(AbTokens.space8),
      child: AbTextField(
        controller: _freeText,
        focusNode: _searchFocus,
        autofocus: true,
        hintText: 'Model id',
        // Committed on submit, not per keystroke: each change is a configure
        // frame, and a half-typed model id is one the judge would try to run.
        onSubmitted: (text) =>
            _pickModel(text.trim().isEmpty ? null : text.trim()),
      ),
    ),
    PanelHint(
      "This machine hasn't heard $judgeLabel list its models — type an id.",
    ),
  ];

  List<Widget> _modelListBranch(List<AgentCapabilityModel> models) {
    final query = _query.trim().toLowerCase();
    final filtered = models.where((m) {
      if (query.isEmpty) return true;
      return m.name.toLowerCase().contains(query) ||
          m.id.toLowerCase().contains(query);
    }).toList();

    return [
      Padding(
        padding: const EdgeInsets.all(AbTokens.space8),
        child: AbTextField(
          controller: _search,
          focusNode: _searchFocus,
          autofocus: true,
          hintText: 'Search models…',
          prefixIcon: AbIcons.search,
        ),
      ),
      const AbSeparator.horizontal(weight: AbSeparatorWeight.strong),
      ConstrainedBox(
        // Nothing else caps this panel's height but the viewport.
        constraints: const BoxConstraints(maxHeight: 240),
        child: filtered.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(AbTokens.space12),
                child: PanelHint('No matching models'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (ctx, index) {
                  final m = filtered[index];
                  return PanelRow(
                    icon: AbIcons.code,
                    label: m.name,
                    selected: m.id == _pick.judgeModel,
                    onTap: () => _pickModel(m.id),
                  );
                },
              ),
      ),
    ];
  }

  String _modelName(List<AgentCapabilityModel> models, String id) {
    final matches = models.where((m) => m.id == id);
    return matches.isEmpty ? id : matches.first.name;
  }
}
