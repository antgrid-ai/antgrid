import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_control_box.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_segmented.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/agent_event.dart';
import '../../models/handler_state.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/capability_catalog.dart';
import '../../providers/providers.dart';
import '../../services/handler_service.dart';

/// The sheet's own gutter. Everything on it lines up on this one inset.
const _gutter = EdgeInsets.symmetric(horizontal: AbTokens.space16);

/// What the posture caption says while nothing is being judged. The presets are
/// stored and inert, and a control that reads as running while every pause
/// escalates is the one claim this sheet must never make.
const handlerPostureParkedBlurb =
    'Stored, but not running — nothing is being judged, so every pause comes '
    'to you whatever this says.';

/// The escalate-only fact on the one surface that can act on it: the judge
/// picker under this line is the fix, so it names the fix rather than stopping
/// at the diagnosis the way the shield tooltip and the arm copy have to.
String handlerJudgeParkedNotice(String? judgeLabel) =>
    "${judgeLabel ?? 'This judge'} can't run headless, so nothing is judged. "
    'Pick one that can and this posture takes effect.';

/// Just the judge half of [HandlerSessionSettingsValue] — what a picker that
/// owns the judge and nothing else hands back. Null tool means the session's
/// own CLI; null model means that CLI's default.
typedef HandlerJudgePick = ({String? judgeTool, String? judgeModel});

/// What a judge pick means on the ARM sheet: nothing is running yet, so the
/// choice is simply the one the session opens under.
const handlerJudgeScopeOnArm = 'Judges this session from the moment it arms.';

/// What a judge pick means once the session is armed. Judge calls are
/// serialised, so a session mid-pass finishes under the judge it started with —
/// said plainly rather than implied, the same reason
/// [HandlerSessionSettings.appliesNextPass] exists.
const handlerJudgeScopeNextPass = 'Takes effect on the next pass.';

/// The tool that will actually judge [terminalId] given an optional per-session
/// [override] — the one resolution every surface naming the judge goes through,
/// so a chip, a notice and the bridge can never name different tools.
String? handlerEffectiveJudge(
  WidgetRef ref,
  String terminalId,
  String? override,
) {
  final service = serviceWhenReady(ref, handlerServiceProvider);
  return override ?? service?.resolvedDefaultTool(terminalId);
}

/// The two per-session choices Handler exposes: which CLI judges its pauses,
/// and how far it leans toward answering them itself.
///
/// One value type shared by both hosts — the first-arm sheet, which collects it
/// and sends it with the arm, and the settings sheet, which commits each change
/// as it is made. A null judge means the session's own tool; a null model means
/// that CLI's default. Personality has no null: every preset is a real choice.
typedef HandlerSessionSettingsValue = ({
  String? judgeTool,
  String? judgeModel,
  HandlerPersonality personality,
});

/// One [HandlerService.arm] call's worth of change: null on a field means
/// "leave the stored value alone", `''` on a judge field means "clear back to
/// default". The shape `arm` already takes, so no caller re-derives it.
typedef HandlerSessionSettingsEdit = ({
  String? judgeTool,
  String? judgeModel,
  HandlerPersonality? personality,
});

/// The edit that turns [from] into [to] — only the fields that MOVED.
///
/// Sending the whole value instead would rewrite a judge pick the sheet merely
/// displayed: a cold settings cache seeds every field null, and a full send
/// would then clear a per-session record on the bridge that this app has not
/// yet been told about.
HandlerSessionSettingsEdit handlerSessionSettingsEdit(
  HandlerSessionSettingsValue from,
  HandlerSessionSettingsValue to,
) => (
  judgeTool: to.judgeTool == from.judgeTool ? null : (to.judgeTool ?? ''),
  judgeModel: to.judgeModel == from.judgeModel ? null : (to.judgeModel ?? ''),
  personality: to.personality == from.personality ? null : to.personality,
);

/// What a sheet opens on for [terminalId], read through the service cache so a
/// disarmed session still offers back what it was last given (see
/// [HandlerService.lastKnownSettings]).
///
/// A session with nothing stored opens on the same preset the bridge would have
/// judged it under, never on a blank control: the sheet has to show what is
/// already true before it can be used to change it.
HandlerSessionSettingsValue handlerSessionSettingsFor(
  HandlerService? service,
  String terminalId,
) {
  final stored = service?.lastKnownSettings(terminalId);
  return (
    judgeTool: stored?.tool,
    judgeModel: stored?.model,
    personality: stored?.personality ?? HandlerPersonality.watchdog,
  );
}

/// The controls, with no chrome and no commit of their own — both hosts own
/// what a change means, and they mean different things (collected into an arm
/// vs. sent as an edit).
///
/// Both halves, in the order the settings sheet wants them. A host that already
/// carries a judge picker of its own (the arm sheet's composer chip) mounts
/// [HandlerPostureControl] alone rather than offering the same value twice.
class HandlerSessionSettings extends StatelessWidget {
  const HandlerSessionSettings({
    super.key,
    required this.terminalId,
    required this.value,
    required this.onChanged,
    this.appliesNextPass = false,
  });

  final String terminalId;
  final HandlerSessionSettingsValue value;
  final ValueChanged<HandlerSessionSettingsValue> onChanged;

  /// Whether a change lands on the pass after this one rather than immediately.
  /// True post-arm: judge calls are serialised, so a session mid-pass finishes
  /// under the posture it started with. Said plainly rather than implied — a
  /// control that looks instant and is not is one the user stops trusting.
  final bool appliesNextPass;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      // The posture leads and the judge follows: how much Handler decides
      // alone is what a user opens this for, while the judge is machinery
      // most sessions never touch.
      HandlerPostureControl(
        terminalId: terminalId,
        value: value,
        onChanged: onChanged,
        appliesNextPass: appliesNextPass,
      ),
      HandlerJudgeControl(
        terminalId: terminalId,
        value: value,
        onChanged: onChanged,
      ),
    ],
  );
}

/// How much Handler decides alone, plus the two lines that qualify it: the
/// posture blurb, and the parked notice when the judge can't run headless.
///
/// The notice stays HERE rather than with the picker it names because it is an
/// answer about the posture — why this control is stored and inert. Its copy
/// never says "below", so it reads true whether the picker that fixes it sits
/// under this block (the settings sheet) or above it (the arm sheet's chip).
class HandlerPostureControl extends ConsumerWidget {
  const HandlerPostureControl({
    super.key,
    required this.terminalId,
    required this.value,
    required this.onChanged,
    this.appliesNextPass = false,
  });

  final String terminalId;
  final HandlerSessionSettingsValue value;
  final ValueChanged<HandlerSessionSettingsValue> onChanged;

  /// See [HandlerSessionSettings.appliesNextPass].
  final bool appliesNextPass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final catalog = ref.watch(agentCatalogProvider);
    // The tool that will actually run, which is what every claim below is about.
    final effectiveJudge = handlerEffectiveJudge(
      ref,
      terminalId,
      value.judgeTool,
    );
    final judgeCapable = effectiveJudge == null
        ? null
        : catalog[effectiveJudge]?.judgeCapable;
    final judgeLabel = effectiveJudge == null
        ? null
        : (catalog[effectiveJudge]?.label ?? effectiveJudge);
    // A judge that cannot go headless runs no decide pass at all — the bridge
    // gates the whole path on this same answer — so the posture here is stored
    // and does nothing until the judge picker changes.
    final parked = judgeCapable == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Head(label: 'How much it handles'),
        Padding(
          padding: _gutter,
          child: AbSegmented<HandlerPersonality>(
            segments: [
              for (final preset in HandlerPersonality.values)
                AbSegment(
                  value: preset,
                  label: handlerPersonalityLabel(preset),
                ),
            ],
            selected: value.personality,
            // Still selectable while parked: the choice is stored and starts
            // working the moment the judge is fixed. It just must not look
            // like it is running.
            inactive: parked,
            onSelect: (preset) => onChanged((
              judgeTool: value.judgeTool,
              judgeModel: value.judgeModel,
              personality: preset,
            )),
          ),
        ),
        _Caption(
          text: parked
              ? handlerPostureParkedBlurb
              : appliesNextPass
              ? '${handlerPersonalityBlurb(value.personality)} Takes effect on the next pass.'
              : handlerPersonalityBlurb(value.personality),
          // The parked line is the load-bearing one on this sheet, not an aside
          // under a control that is working.
          color: parked ? p.textSecondary : p.textMuted,
        ),
        // This is the one class of surface where the warning is actionable;
        // everywhere else it appears it only diagnoses.
        if (parked) _Notice(text: handlerJudgeParkedNotice(judgeLabel)),
      ],
    );
  }
}

/// Which CLI judges the session's pauses, and under which model.
///
/// Split out from the posture so a host that already names the judge somewhere
/// else can leave this block off — two controls writing one value is a state
/// the user has to reconcile.
class HandlerJudgeControl extends ConsumerWidget {
  const HandlerJudgeControl({
    super.key,
    required this.terminalId,
    required this.value,
    required this.onChanged,
  });

  final String terminalId;
  final HandlerSessionSettingsValue value;
  final ValueChanged<HandlerSessionSettingsValue> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(agentCatalogProvider);
    final judgeTools = ref.watch(judgeCapableToolsProvider);
    final defaultTool = handlerEffectiveJudge(ref, terminalId, null);
    final effectiveJudge = value.judgeTool ?? defaultTool;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(
            AbTokens.space16,
            AbTokens.space14,
            AbTokens.space16,
            AbTokens.space14,
          ),
          child: AbSeparator.horizontal(),
        ),
        const _Head(label: 'Judged by'),
        _PickerRow(
          value: value.judgeTool == null
              ? (defaultTool == null ? 'Default' : 'Default ($defaultTool)')
              : (catalog[value.judgeTool]?.label ?? value.judgeTool!),
          entries: [
            AbMenuItem(label: 'Default', value: ''),
            for (final tool in judgeTools)
              AbMenuItem(label: catalog[tool]?.label ?? tool, value: tool),
          ],
          onSelected: (picked) => onChanged((
            judgeTool: picked.isEmpty ? null : picked,
            // Cleared, never carried: a model id is a name only its own CLI
            // answers to, so keeping it across a tool change hands the new
            // judge a flag it rejects on every pass.
            judgeModel: null,
            personality: value.personality,
          )),
        ),
        // A sub-label rather than a peer heading: a model names nothing without
        // the judge above it, so the two rows are one decision.
        const _Head(label: 'Model', sub: true),
        _ModelControl(
          judgeTool: effectiveJudge,
          model: value.judgeModel,
          onChanged: (model) => onChanged((
            judgeTool: value.judgeTool,
            judgeModel: model,
            personality: value.personality,
          )),
        ),
      ],
    );
  }
}

/// The judge's model, as a picker when this machine has heard that CLI list its
/// models and as free text otherwise.
///
/// The list comes from the capability catalog a CHAT session of that tool wrote
/// (`capability_catalog.dart`), which is why the field is not a fallback for a
/// broken path: a machine that has only ever run this agent in a terminal has
/// no catalog to offer, and typing the id is then the only way to name one.
class _ModelControl extends ConsumerStatefulWidget {
  const _ModelControl({
    required this.judgeTool,
    required this.model,
    required this.onChanged,
  });

  final String? judgeTool;
  final String? model;
  final ValueChanged<String?> onChanged;

  @override
  ConsumerState<_ModelControl> createState() => _ModelControlState();
}

class _ModelControlState extends ConsumerState<_ModelControl> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.model ?? '',
  );

  @override
  void didUpdateWidget(_ModelControl old) {
    super.didUpdateWidget(old);
    // Only when the value moved underneath us — a judge change clears the model,
    // and the field would otherwise keep offering the previous CLI's id back.
    // Never on every rebuild: that would fight the user's cursor as they type.
    if (widget.model != old.model && (widget.model ?? '') != _controller.text) {
      _controller.text = widget.model ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tool = widget.judgeTool;
    final models = tool == null
        ? const <AgentCapabilityModel>[]
        : cachedModelsFor(ref, tool);
    if (models.isEmpty) {
      return Padding(
        padding: _gutter,
        child: AbTextField(
          controller: _controller,
          hintText: 'Default',
          // Committed on submit, not per keystroke: each change is a configure
          // frame, and a half-typed model id is one the judge would try to run.
          onSubmitted: (text) =>
              widget.onChanged(text.trim().isEmpty ? null : text.trim()),
        ),
      );
    }
    final matches = models.where((m) => m.id == widget.model);
    final selected = matches.isEmpty ? null : matches.first;
    return _PickerRow(
      value: selected?.name ?? 'Default',
      entries: [
        AbMenuItem(label: 'Default', value: ''),
        for (final m in models) AbMenuItem(label: m.name, value: m.id),
      ],
      onSelected: (picked) => widget.onChanged(picked.isEmpty ? null : picked),
    );
  }
}

/// A one-line value that opens a menu under itself. Not [AbSegmented]: the judge
/// list is however many agents the catalog describes, and a segmented control
/// that grows with the registry stops fitting a phone.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.value,
    required this.entries,
    required this.onSelected,
  });

  final String value;
  final List<AbMenuEntry> entries;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: _gutter,
      child: Builder(
        builder: (anchorContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final anchor = abMenuAnchorRect(anchorContext);
            if (anchor == null) return;
            final picked = await showAbMenu<String>(
              context: anchorContext,
              anchorRect: anchor,
              entries: entries,
            );
            if (picked != null) onSelected(picked);
          },
          // AbControlBox rather than a box of its own: the model row swaps
          // between this trigger and an AbTextField depending on whether the
          // machine has ever heard that CLI list its models, and only the
          // shared recipe keeps the two the same height on every machine.
          child: AbControlBox(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textPrimary,
                    ),
                  ),
                ),
                AbIcon(AbIcons.chevronDown, size: 12, color: p.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A block label at the sheet's gutter. [sub] marks a row that belongs to the
/// block above it rather than opening a new one, and is quieter for it.
class _Head extends StatelessWidget {
  const _Head({required this.label, this.sub = false});

  final String label;
  final bool sub;

  @override
  Widget build(BuildContext context) => AbSectionHeader(
    label: label,
    color: sub ? context.antgrid.textDisabled : null,
    padding: EdgeInsets.fromLTRB(
      AbTokens.space16,
      sub ? AbTokens.space10 : 0,
      AbTokens.space16,
      AbTokens.space6,
    ),
  );
}

/// The explanatory line under a control.
class _Caption extends StatelessWidget {
  const _Caption({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      AbTokens.space6,
      AbTokens.space16,
      0,
    ),
    child: Text(
      text,
      style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: color),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space6,
        AbTokens.space16,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space2),
            child: AbIcon(AbIcons.warning, size: 11, color: p.warning),
          ),
          const SizedBox(width: AbTokens.space6),
          Expanded(
            child: Text(
              text,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the settings sheet for an ARMED [terminalId] — the PA bar's posture
/// chip and the Handler tab's armed menu are its two doors, and both exist only
/// while the session is armed.
///
/// Every change commits on the spot as a `handler:configure` carrying `armed:
/// true`, which is the bridge's edit path: there is no Save, and no state here
/// that a dismissal could strand.
Future<void> showHandlerSessionSettingsSheet(
  BuildContext context,
  String terminalId,
) => showAbAdaptiveSheet<void>(
  context,
  child: _SettingsSheet(terminalId: terminalId),
);

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet({required this.terminalId});

  final String terminalId;

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  HandlerSessionSettingsValue? _value;

  /// Seeded once, from the service rather than from a provider: reseeding on
  /// every rebuild would let the status snapshot that CONFIRMS an edit land
  /// mid-gesture and reset the control the user is still using.
  HandlerSessionSettingsValue get _current =>
      _value ??
      handlerSessionSettingsFor(
        focusedServiceOrNull(ref.container, (s) => s.handlerService),
        widget.terminalId,
      );

  void _commit(HandlerSessionSettingsValue next) {
    final edit = handlerSessionSettingsEdit(_current, next);
    setState(() => _value = next);
    // `armed: true` on an already-armed session is the bridge's EDIT path, not
    // a second arm — which is why this sheet is only ever reachable from a
    // surface that exists while the session is armed.
    focusedServiceOrNull(ref.container, (s) => s.handlerService)?.arm(
      terminalId: widget.terminalId,
      judgeTool: edit.judgeTool,
      judgeModel: edit.judgeModel,
      personality: edit.personality,
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: abDialogTitlePadding,
        child: abDialogTitle(
          'Handler settings',
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
      HandlerSessionSettings(
        terminalId: widget.terminalId,
        value: _current,
        onChanged: _commit,
        appliesNextPass: true,
      ),
      const SizedBox(height: AbTokens.space16),
    ],
  );
}
