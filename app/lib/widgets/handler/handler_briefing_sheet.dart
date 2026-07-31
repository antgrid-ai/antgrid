import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/ab_message.dart';
import '../../models/handler_state.dart';
import '../../services/handler_service.dart';

// Local backstop only — deliberately longer than the bridge's own plan timeout
// (PLAN_TIMEOUT_MS in bridge/src/handler/judge.ts, 45s) so the bridge's fallback
// result always wins the race and the sheet never gives up before the bridge
// does. Raise both together or the race inverts.
const _kPlanTimeout = Duration(seconds: 50);

const _kSkeletalWakeFor = [
  'Anything destructive or irreversible',
  'Repeated failures',
];

// The tools the bridge's judge can drive headlessly (mirror of the entries
// carrying a `judge` in bridge/src/agents/registry.ts).
const _kJudgeTools = ['claude-code', 'codex', 'opencode'];

/// The user's choice from [showHandlerBriefingSheet]: arm with [brief]
/// (respecting [notifyOnly]), or — when editing an already-armed session —
/// disarm it instead ([disarm]; [brief]/[notifyOnly] are ignored by callers
/// in that case).
class HandlerArmChoice {
  final HandlerBrief brief;
  final bool notifyOnly;

  /// This SESSION's judge choice. Explicit values only when the user touched
  /// the picker in this sheet instance: `''` = clear to the session's default
  /// tool / the judge CLI's default model, a name sets it. Null = untouched —
  /// the keys are omitted on the wire so the bridge keeps the stored record.
  /// (An untouched picker can show a blank Default after a plan timeout even
  /// when a pick exists on disk; sending that `''` would wipe it.)
  final String? judgeTool;
  final String? judgeModel;
  final bool disarm;
  const HandlerArmChoice({
    required this.brief,
    required this.notifyOnly,
    this.judgeTool,
    this.judgeModel,
    this.disarm = false,
  });
}

/// Opens the arm flow for [terminalId]: requests a plan, shows loading, then
/// the editable brief. Returns the user's arming choice or null on cancel.
Future<HandlerArmChoice?> showHandlerBriefingSheet(
  BuildContext context, {
  required String terminalId,
  required HandlerService service,
  HandlerBrief? initialBrief,
  bool? initialNotifyOnly,
}) {
  return showAbAdaptiveSheet<HandlerArmChoice>(
    context,
    maxWidth: 480,
    child: _HandlerBriefingFlow(
      terminalId: terminalId,
      service: service,
      initialBrief: initialBrief,
      initialNotifyOnly: initialNotifyOnly,
    ),
  );
}

enum _Phase { loading, editing }

class _HandlerBriefingFlow extends StatefulWidget {
  const _HandlerBriefingFlow({
    required this.terminalId,
    required this.service,
    required this.initialBrief,
    required this.initialNotifyOnly,
  });

  final String terminalId;
  final HandlerService service;
  final HandlerBrief? initialBrief;
  final bool? initialNotifyOnly;

  @override
  State<_HandlerBriefingFlow> createState() => _HandlerBriefingFlowState();
}

class _HandlerBriefingFlowState extends State<_HandlerBriefingFlow> {
  _Phase _phase = _Phase.loading;
  StreamSubscription<HandlerPlanResultMessage>? _planSub;
  Timer? _timeoutTimer;

  late String _taskSummary;
  late List<String> _willHandle;
  late List<String> _wakeFor;
  late final TextEditingController _doneWhenController;
  late List<String> _thenItems;
  // Keys so _buildBrief can flush text still sitting in an add-line field:
  // the footer's AbButton doesn't steal focus, so the sections' blur-commit
  // hasn't fired by the time Arm reads the lists.
  final _willHandleKey = GlobalKey<_BulletListSectionState>();
  final _wakeForKey = GlobalKey<_BulletListSectionState>();
  final _thenKey = GlobalKey<_BulletListSectionState>();
  late bool _notifyOnly;
  // Judge overrides ('' = default), seeded from the last status snapshot.
  late String _judgeTool;
  late final TextEditingController _judgeModelController;
  // True once the user has touched the judge tool/model picker in THIS sheet
  // instance. It gates everything the sheet says about the judge: a planResult
  // echo only lands while untouched (see [_onPlanResult]), and both plan
  // requests and Arm send explicit judge values only when touched — an
  // untouched picker's value is not user intent (after a plan timeout it can
  // read blank while a pick still exists on disk), so it must never override
  // or rewrite the stored choice.
  bool _judgePickerTouched = false;
  // Suppresses [_onJudgeModelEdited] while [_onPlanResult] applies a
  // planResult echo to [_judgeModelController] programmatically.
  bool _applyingJudgeEcho = false;

  // Set on a fallback plan result — shown as a dismissable-by-edit banner.
  String? _banner;
  // Set when a plan result arrived with both a previousBrief (now the
  // editing baseline) and a freshly generated brief — offered as a
  // secondary action rather than applied outright, so a re-arm never
  // silently discards the user's last-armed brief.
  HandlerBrief? _freshBrief;

  @override
  void initState() {
    super.initState();
    _doneWhenController = TextEditingController();
    // Preserve the armed session's notify-only setting when editing; defaulting
    // blindly to false would silently flip a watch-only session into one that
    // acts on the PTY the moment the user re-arms. Fresh arms seed from the
    // project's configured default (handler-config.json v2).
    _notifyOnly =
        widget.initialNotifyOnly ??
        widget.service.currentState.defaultNotifyOnly;
    final judgeSeed = widget.service.lastKnownJudge(widget.terminalId);
    _judgeTool = judgeSeed?.tool ?? '';
    _judgeModelController = TextEditingController(text: judgeSeed?.model ?? '');
    // Added after the seed above so seeding doesn't itself count as a touch.
    _judgeModelController.addListener(_onJudgeModelEdited);
    // Re-arm within this app run (or editing an already-armed session)
    // starts directly from the known brief — no plan call, no loading.
    final startingBrief =
        widget.initialBrief ?? widget.service.lastKnownBrief(widget.terminalId);
    if (startingBrief != null) {
      _applyBrief(startingBrief);
      _phase = _Phase.editing;
    } else {
      _startPlanRequest();
    }
  }

  void _onJudgeModelEdited() {
    if (_applyingJudgeEcho) return;
    _judgePickerTouched = true;
  }

  @override
  void dispose() {
    _planSub?.cancel();
    _timeoutTimer?.cancel();
    _judgeModelController.removeListener(_onJudgeModelEdited);
    _doneWhenController.dispose();
    _judgeModelController.dispose();
    super.dispose();
  }

  void _applyBrief(HandlerBrief brief) {
    _taskSummary = brief.taskSummary;
    _willHandle = List.of(brief.willHandle);
    _wakeFor = List.of(brief.wakeFor);
    _doneWhenController.text = brief.doneWhen ?? '';
    _thenItems = List.of(brief.thenItems);
  }

  void _applySkeletal() {
    _taskSummary = '';
    _willHandle = [];
    _wakeFor = List.of(_kSkeletalWakeFor);
    _doneWhenController.text = '';
    _thenItems = [];
  }

  /// Sends the picker's current values as a one-shot judge override only once
  /// the user has touched the picker. Untouched, the keys are omitted so the
  /// bridge's stored choice drives the draft — an untouched picker's `''` is
  /// not a choice (it can be a plan-timeout artifact while a pick exists on
  /// disk), and sending it would force the wrong judge.
  void _startPlanRequest() {
    _planSub?.cancel();
    _timeoutTimer?.cancel();
    widget.service.requestPlan(
      widget.terminalId,
      judgeTool: _judgePickerTouched ? _judgeTool : null,
      judgeModel: _judgePickerTouched
          ? _judgeModelController.text.trim()
          : null,
    );
    _planSub = widget.service.planResultStream
        .where((m) => m.terminalId == widget.terminalId)
        .listen(_onPlanResult);
    _timeoutTimer = Timer(_kPlanTimeout, _onPlanTimeout);
  }

  void _onPlanTimeout() {
    if (!mounted || _phase != _Phase.loading) return;
    _planSub?.cancel();
    setState(() {
      _applySkeletal();
      _banner = "Couldn't read the session — write your own brief.";
      _phase = _Phase.editing;
    });
  }

  void _onPlanResult(HandlerPlanResultMessage msg) {
    if (!mounted || _phase != _Phase.loading) return;
    _planSub?.cancel();
    _timeoutTimer?.cancel();
    final previousBrief = HandlerBrief.fromWire(msg.previousBrief);
    setState(() {
      if (msg.fallback) {
        if (previousBrief != null) {
          _applyBrief(previousBrief);
        } else {
          _applySkeletal();
        }
        _banner = "Couldn't read the session — write your own brief.";
        _freshBrief = null;
      } else {
        final generated = HandlerBrief.fromWire(msg.brief);
        if (previousBrief != null) {
          // Spec's re-arm rule survives app restarts: the previous brief is
          // still the starting point, with the fresh plan offered alongside.
          _applyBrief(previousBrief);
          _freshBrief = generated;
        } else if (generated != null) {
          _applyBrief(generated);
          _freshBrief = null;
        } else {
          // Malformed payload — land on an editable skeletal brief rather
          // than stranding the user in the loading state.
          _applySkeletal();
        }
        _banner = null;
      }
      // Adopt the STORED judge the bridge echoes on every planResult — this is
      // how a freshly restarted app (empty caches) seeds the picker from a
      // disarmed session's on-disk record. Skipped once the user has touched
      // the picker in this sheet instance, so a slow initial plan call can't
      // land after the user already made — and started acting on — a choice.
      if (!_judgePickerTouched) {
        _judgeTool = msg.judgeTool ?? '';
        _applyingJudgeEcho = true;
        _judgeModelController.text = msg.judgeModel ?? '';
        _applyingJudgeEcho = false;
      }
      _phase = _Phase.editing;
    });
  }

  void _regenerate() {
    setState(() {
      _phase = _Phase.loading;
      _banner = null;
      _freshBrief = null;
    });
    _startPlanRequest();
  }

  void _useFreshPlan() {
    final fresh = _freshBrief;
    if (fresh == null) return;
    setState(() {
      _applyBrief(fresh);
      _freshBrief = null;
    });
  }

  bool get _canArm =>
      _willHandle.isNotEmpty || _wakeFor.isNotEmpty || _thenItems.isNotEmpty;

  HandlerBrief _buildBrief() {
    // Uncommitted add-line text is still the user's intent — commit it into
    // the lists before reading them.
    for (final k in [_willHandleKey, _wakeForKey, _thenKey]) {
      k.currentState?.commitPending();
    }
    final doneWhen = _doneWhenController.text.trim();
    return HandlerBrief(
      taskSummary: _taskSummary,
      willHandle: _willHandle,
      wakeFor: _wakeFor,
      doneWhen: doneWhen.isEmpty ? null : doneWhen,
      thenItems: _thenItems,
    );
  }

  void _pop(HandlerArmChoice? choice) => Navigator.pop(context, choice);

  @override
  Widget build(BuildContext context) {
    return _phase == _Phase.loading ? _buildLoading() : _buildEditing(context);
  }

  Widget _buildLoading() {
    return Padding(
      padding: abDialogTitlePadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          abDialogTitle('Handler brief', onClose: () => _pop(null)),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AbTokens.space24),
            child: AbLoading(message: 'Reading session…'),
          ),
        ],
      ),
    );
  }

  Widget _buildEditing(BuildContext context) {
    final p = context.antgrid;
    // The desktop Dialog chrome (showAbAdaptiveSheet) only bounds width, not
    // height — cap it here so a brief with many added lines scrolls inside
    // the sheet instead of growing the dialog past the viewport.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 640),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: abDialogTitlePadding,
            child: Row(
              children: [
                Expanded(
                  child: abDialogTitle(
                    'Handler brief',
                    onClose: () => _pop(null),
                  ),
                ),
                AbIconButton(
                  icon: AbIcons.refresh,
                  tooltip: 'Regenerate from the live session',
                  onTap: _regenerate,
                ),
              ],
            ),
          ),
          if (_banner != null) _Banner(text: _banner!),
          if (_freshBrief != null) _FreshPlanOffer(onUse: _useFreshPlan),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_taskSummary.trim().isNotEmpty) _buildWhereYouAre(p),
                  _BulletListSection(
                    key: _willHandleKey,
                    label: "I'LL HANDLE",
                    items: _willHandle,
                    addHint: 'e.g. Restart the dev server on crash',
                    onChanged: (v) => setState(() => _willHandle = v),
                  ),
                  _BulletListSection(
                    key: _wakeForKey,
                    label: 'WAKE YOU FOR',
                    items: _wakeFor,
                    addHint: 'e.g. Schema or migration changes',
                    onChanged: (v) => setState(() => _wakeFor = v),
                  ),
                  _buildDoneWhen(p),
                  _BulletListSection(
                    key: _thenKey,
                    label: 'THEN',
                    items: _thenItems,
                    addHint: 'e.g. Run the full test suite',
                    onChanged: (v) => setState(() => _thenItems = v),
                  ),
                  _buildNotifyOnly(p),
                  _buildJudge(p),
                ],
              ),
            ),
          ),
          _buildFooter(p),
        ],
      ),
    );
  }

  Widget _buildWhereYouAre(AbColors p) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      AbTokens.space12,
      AbTokens.space16,
      AbTokens.space4,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('WHERE YOU ARE'),
        const SizedBox(height: AbTokens.space4),
        Text(
          _taskSummary,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: p.textMuted,
          ),
        ),
      ],
    ),
  );

  Widget _buildDoneWhen(AbColors p) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      AbTokens.space12,
      AbTokens.space16,
      AbTokens.space4,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('DONE WHEN'),
        const SizedBox(height: AbTokens.space4),
        AbTextField(
          controller: _doneWhenController,
          hintText: 'Optional — e.g. tests pass and the PR is open',
        ),
      ],
    ),
  );

  Widget _buildNotifyOnly(AbColors p) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      AbTokens.space12,
      AbTokens.space16,
      AbTokens.space12,
    ),
    child: GestureDetector(
      onTap: () => setState(() => _notifyOnly = !_notifyOnly),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          // Design-system checkbox built from primitives: a bordered box
          // filled with the accent color when on, holding an AbIcon check.
          // The Antgrid system has no checkbox widget and raw Icons.* is
          // banned, so this must be hand-built (mirrors the old enable
          // sheet's pattern).
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _notifyOnly ? p.accent : const Color(0x00000000),
              borderRadius: AbTokens.borderRadius,
              border: Border.all(
                color: _notifyOnly ? p.accent : p.borderStrong,
              ),
            ),
            child: _notifyOnly
                ? AbIcon(AbIcons.check, size: 12, color: p.accentForeground)
                : null,
          ),
          const SizedBox(width: AbTokens.space8),
          Text('Notify only', style: AbTokens.sansStyle(color: p.textPrimary)),
        ],
      ),
    ),
  );

  String get _defaultToolLabel =>
      widget.service.resolvedDefaultTool(widget.terminalId) ?? 'agent tool';

  Future<void> _pickJudgeTool(BuildContext anchorContext) async {
    final anchorRect = abMenuAnchorRect(anchorContext);
    if (anchorRect == null) return;
    final picked = await showAbMenu<String>(
      context: anchorContext,
      anchorRect: anchorRect,
      header: 'Judge tool',
      entries: [
        AbMenuItem(label: 'Default ($_defaultToolLabel)', value: ''),
        for (final t in _kJudgeTools) AbMenuItem(label: t, value: t),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      // A model is tool-specific (e.g. gpt-5.3-codex is meaningless to
      // claude-code) — carrying the previous tool's model over would arm the
      // judge with an invalid --model flag. Clear it when the tool changes.
      if (picked != _judgeTool) _judgeModelController.clear();
      _judgeTool = picked;
      _judgePickerTouched = true;
    });
  }

  Widget _buildJudge(AbColors p) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      AbTokens.space4,
      AbTokens.space16,
      AbTokens.space12,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('JUDGE'),
        const SizedBox(height: AbTokens.space4),
        Text(
          "Which CLI reviews this session's events.",
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: p.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        Row(
          children: [
            Expanded(
              child: Builder(
                builder: (anchorContext) => GestureDetector(
                  onTap: () => _pickJudgeTool(anchorContext),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AbTokens.space8,
                      vertical: AbTokens.space6,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: p.borderDefault),
                      borderRadius: AbTokens.borderRadius5,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _judgeTool.isEmpty
                                ? 'Default ($_defaultToolLabel)'
                                : _judgeTool,
                            // Tool/model ids are code-like → mono.
                            style: AbTokens.monoStyle(
                              fontSize: AbTokens.fontXs,
                              color: p.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
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
            const SizedBox(width: AbTokens.space8),
            Expanded(
              child: AbTextField(
                controller: _judgeModelController,
                hintText: 'Model — CLI default',
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _buildFooter(AbColors p) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      0,
      AbTokens.space16,
      AbTokens.space16,
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AbButton(label: 'Cancel', onTap: () => _pop(null)),
        if (widget.initialBrief != null) ...[
          const SizedBox(width: AbTokens.space8),
          AbButton(
            label: 'Disarm',
            onTap: () => _pop(
              HandlerArmChoice(
                brief: _buildBrief(),
                notifyOnly: _notifyOnly,
                disarm: true,
              ),
            ),
          ),
        ],
        const SizedBox(width: AbTokens.space8),
        AbButton(
          label: 'Arm',
          variant: AbButtonVariant.primary,
          onTap: _canArm
              ? () => _pop(
                  HandlerArmChoice(
                    brief: _buildBrief(),
                    notifyOnly: _notifyOnly,
                    // Untouched → null → keys omitted → stored pick survives.
                    // Seeded-untouched sends nothing too, which is equivalent:
                    // the seed came from the stored record in the first place.
                    judgeTool: _judgePickerTouched ? _judgeTool : null,
                    judgeModel: _judgePickerTouched
                        ? _judgeModelController.text.trim()
                        : null,
                  ),
                )
              : null,
        ),
      ],
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: AbTokens.sansStyle(
      fontSize: AbTokens.fontXxs,
      fontWeight: FontWeight.w500,
      color: context.antgrid.textSecondary,
    ).copyWith(letterSpacing: 1.5),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space8,
        AbTokens.space16,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space6,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: p.borderSubtle),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        children: [
          AbIcon(AbIcons.info, size: 12, color: p.textMuted),
          const SizedBox(width: AbTokens.space6),
          Expanded(
            child: Text(
              text,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FreshPlanOffer extends StatelessWidget {
  const _FreshPlanOffer({required this.onUse});
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space8,
        AbTokens.space16,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space6,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: p.borderSubtle),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Starting from your previous brief.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textMuted,
              ),
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          AbButton(label: 'Use fresh plan', compact: true, onTap: onUse),
        ],
      ),
    );
  }
}

/// One editable bullet-list section ("I'll handle" / "Wake you for" /
/// "Then"): existing rows with a delete action, plus a trailing "add line"
/// row that turns into a text field on tap.
class _BulletListSection extends StatefulWidget {
  const _BulletListSection({
    super.key,
    required this.label,
    required this.items,
    required this.addHint,
    required this.onChanged,
  });

  final String label;
  final List<String> items;
  final String addHint;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_BulletListSection> createState() => _BulletListSectionState();
}

class _BulletListSectionState extends State<_BulletListSection> {
  bool _adding = false;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Blur without an explicit Enter still commits (non-empty) or collapses
    // the add row (empty) — tapping elsewhere shouldn't silently drop text.
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus || !_adding) return;
    _submit(_controller.text);
  }

  /// Commit text typed but not yet submitted. The parent calls this before
  /// building the brief: footer buttons don't take focus, so the blur-commit
  /// above hasn't fired when Arm is tapped.
  void commitPending() {
    if (_adding) _submit(_controller.text);
  }

  void _remove(int index) {
    final next = List<String>.of(widget.items)..removeAt(index);
    widget.onChanged(next);
  }

  void _submit(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      setState(() => _adding = false);
      return;
    }
    widget.onChanged([...widget.items, text]);
    _controller.clear();
    // Stay in adding mode for rapid multi-line entry.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            AbTokens.space12,
            AbTokens.space16,
            AbTokens.space4,
          ),
          child: _SectionLabel(widget.label),
        ),
        for (var i = 0; i < widget.items.length; i++)
          AbListRow(
            title: Text(widget.items[i]),
            actions: [
              AbRowAction(
                icon: AbIcons.close,
                tooltip: 'Remove',
                onTap: () => _remove(i),
              ),
            ],
          ),
        if (_adding)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space16,
              vertical: AbTokens.space4,
            ),
            child: AbTextField(
              controller: _controller,
              focusNode: _focusNode,
              hintText: widget.addHint,
              autofocus: true,
              onSubmitted: _submit,
            ),
          )
        else
          AbListRow(
            leading: AbIcon(AbIcons.add, size: 12, color: p.accent),
            title: Text(
              'Add line',
              style: AbTokens.sansStyle(color: p.textMuted),
            ),
            onTap: () => setState(() => _adding = true),
          ),
      ],
    );
  }
}
