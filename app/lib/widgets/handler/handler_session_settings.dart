import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_control_box.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/agent_event.dart';
import '../../models/handler_state.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/capability_catalog.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import '../../services/handler_service.dart';
import '../../util/detached.dart';

/// The sheet's own gutter. Everything on it lines up on this one inset.
const _gutter = EdgeInsets.symmetric(horizontal: AbTokens.space16);

/// The escalate-only fact on the one surface that can act on it: the judge
/// picker under this line is the fix, so it names the fix rather than stopping
/// at the diagnosis the way the shield tooltip and the arm copy have to.
///
/// It names no lens, because the default has none to name: what a parked judge
/// suspends is judging itself, which is true whatever the session looks for.
String handlerJudgeParkedNotice(String? judgeLabel) =>
    "${judgeLabel ?? 'This judge'} can't run headless, so nothing is judged. "
    'Pick one that can and judging resumes.';

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
  // Watched for its subscription, not its value: `resolvedDefaultTool` reads
  // the SessionsService's CURRENT state directly, which notifies nothing. The
  // watch belongs here rather than at each call site — a modal route that does
  // not rebuild on unrelated churn (the arm sheet, the settings sheet) would
  // otherwise resolve the judge once, before the session list has filled in,
  // and keep naming the wrong CLI for its whole life.
  ref.watch(activeSessionsProvider);
  final service = serviceWhenReady(ref, handlerServiceProvider);
  return override ?? service?.resolvedDefaultTool(terminalId);
}

/// The per-session choices Handler exposes: which CLI judges its pauses, and
/// what that judge looks for while it does.
///
/// One value type shared by both hosts — the arm sheet, which collects it
/// and sends it with the arm, and the settings sheet, which commits each change
/// as it is made. A null judge means the session's own tool; a null model means
/// that CLI's default. A null [lens] is NOT the unnamed default: it means this
/// app has not been told what this session judges under (see [HandlerLensPick]),
/// and the control showing it must render with nothing selected rather than
/// paint a pick nobody stated.
typedef HandlerSessionSettingsValue = ({
  String? judgeTool,
  String? judgeModel,
  HandlerLensPick? lens,
});

/// One [HandlerService.arm] call's worth of change: null on a field means
/// "leave the stored value alone", `''` means "clear back to default" — the
/// unnamed default for [role], no brief for [brief]. The shape `arm` already
/// takes, so no caller re-derives it.
typedef HandlerSessionSettingsEdit = ({
  String? judgeTool,
  String? judgeModel,
  String? role,
  String? brief,
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
) {
  final toolMoved = to.judgeTool != from.judgeTool;
  final fromLens = from.lens;
  final toLens = to.lens;
  return (
    judgeTool: toolMoved ? (to.judgeTool ?? '') : null,
    // A tool change ALWAYS carries the model, even when both sides read null:
    // this app's view of the model is null whenever its cache is cold, and
    // omitting the field then leaves the previous CLI's id on the bridge under
    // the new judge — a flag it rejects on every pass, which is the one thing
    // clearing the model across a tool change exists to prevent.
    judgeModel: toolMoved || to.judgeModel != from.judgeModel
        ? (to.judgeModel ?? '')
        : null,
    // A pick made over a seed this app was never told is ALWAYS a change. The
    // `from` side reads null on a cold cache and can name an id this build
    // cannot, so diffing against it is what would leave a session under a lens
    // that one tap on the default is supposed to replace.
    role:
        toLens != null && (fromLens == null || toLens.roleId != fromLens.roleId)
        ? (toLens.roleId ?? '')
        : null,
    brief:
        toLens != null &&
            (fromLens == null || (toLens.brief ?? '') != (fromLens.brief ?? ''))
        ? (toLens.brief ?? '')
        : null,
  );
}

/// What a sheet opens on for [terminalId], read through the service cache so a
/// disarmed session still offers back what it was last given (see
/// [HandlerService.lastKnownSettings]).
///
/// The lens is carried through UNCOERCED: a machine that has never advertised
/// lenses reports no pick, and a cold cache holds none either, neither of which
/// is a session running the unnamed default. Painting the default there would
/// put a lens on screen as a live fact and then send nothing when the user
/// chose the value already displayed.
HandlerSessionSettingsValue handlerSessionSettingsFor(
  HandlerService? service,
  String terminalId,
) {
  final stored = service?.lastKnownSettings(terminalId);
  return (
    judgeTool: stored?.tool,
    judgeModel: stored?.model,
    lens: stored?.lens,
  );
}

/// The controls, with no chrome and no commit of their own — both hosts own
/// what a change means, and they mean different things (collected into an arm
/// vs. sent as an edit).
///
/// Both halves, in the order the settings sheet wants them. A host that already
/// carries a judge picker of its own (the arm sheet's composer chip) mounts
/// [HandlerLensControl] alone rather than offering the same value twice.
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
  /// under the lens it started with. Said plainly rather than implied — a
  /// control that looks instant and is not is one the user stops trusting.
  final bool appliesNextPass;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      // The lens leads and the judge follows: what the judge looks for is what
      // a user opens this for, while which CLI judges is machinery most
      // sessions never touch.
      HandlerLensControl(
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

/// What Handler holds every session to, the pick for what it adds on top of
/// that, and the lines that qualify it: the per-preset caption, the "Your own"
/// panel, and the parked notice when the judge can't run headless.
///
/// The four presets and the user-authored [handlerLensOwnLabel] are ONE radio
/// group — chips behaving identically, never presets plus a disclosure
/// (redesign spec §2, §3.2). There is no chip for adding NOTHING: that is the
/// floor line's own subject and the state a session starts in, so a chip for it
/// offered the user a choice that was already made. A lens ADDS
/// questions and nothing else — the bridge's rules own where handling gives
/// way to escalating — so nothing here may read as a dial over how much the
/// session decides alone.
///
/// The notice stays HERE rather than with the picker it names because it is an
/// answer about the lens — why this control is stored and inert. Its copy
/// never says "below", so it reads true whether the picker that fixes it sits
/// under this block (the settings sheet) or above it (the arm sheet's chip).
class HandlerLensControl extends ConsumerStatefulWidget {
  const HandlerLensControl({
    super.key,
    required this.terminalId,
    required this.value,
    required this.onChanged,
    this.appliesNextPass = false,
    this.commitBriefOnEdit = false,
    this.onRoleTapped,
    this.onBriefEdited,
  });

  final String terminalId;
  final HandlerSessionSettingsValue value;
  final ValueChanged<HandlerSessionSettingsValue> onChanged;

  /// See [HandlerSessionSettings.appliesNextPass].
  final bool appliesNextPass;

  /// Whether a keystroke in the "Your own" panel is a commit. True only for a
  /// host that collects the value and sends it ONCE (the arm sheet). Every
  /// commit on the settings sheet is a configure frame, and the bridge's edit
  /// path clears `lastJudgedContextHash` unconditionally — so a per-keystroke
  /// commit there buys a real judge pass per character.
  final bool commitBriefOnEdit;

  /// Fired on every tap of a lens chip, including the one already selected —
  /// picking "Your own" counts too, since it is exclusive with the presets the
  /// same way they are exclusive with each other (§9). A host whose seed may
  /// not be what the far end holds needs to know a control was ANSWERED, which
  /// is not the same question as whether the value ended up different — see
  /// the arm sheet's touch flags.
  final VoidCallback? onRoleTapped;

  /// Fired on every edit of the "Your own" panel's text.
  final VoidCallback? onBriefEdited;

  @override
  ConsumerState<HandlerLensControl> createState() =>
      _HandlerLensControlState();
}

/// Local, never-on-wire id for the sixth chip. A user lens has no
/// [HandlerLens] value and no wire role id (redesign spec §13 — an id on the
/// wire is what keeps a PRESET's text bridge-authored) so this control needs a
/// marker of its own to route a tap; [handlerLensFromWire] must never resolve
/// it to a real lens.
const _ownChipId = '__own__';

class _HandlerLensControlState extends ConsumerState<HandlerLensControl> {
  /// Whether the sixth chip is the one showing, tracked apart from
  /// [HandlerSessionSettingsValue.lens] because a freshly-picked "Your own"
  /// with nothing typed yet is, on the wire, indistinguishable from
  /// [handlerLensDefaultLabel] — both are `roleId: null, brief: ""`. Only
  /// unambiguous external evidence (a real role id, or a brief that actually
  /// arrived) is allowed to move this without a tap; see [didUpdateWidget].
  late bool _ownSelected;

  /// The user's own text, held across a preset switch (redesign spec §6: the
  /// draft survives locally and only an explicit clear discards it) — a commit
  /// never hands this straight to [HandlerLensControl.onChanged]; it sends the
  /// `"; "`-joined string instead (§8, [handlerJoinOwnLensLines]).
  late final TextEditingController _ownController;

  /// Bumped on every tap of the sixth chip, which is what moves the cursor into
  /// the panel's field. A counter rather than an autofocus flag for two
  /// reasons: the chip stays tappable once selected, and a second tap arrives
  /// with the field already mounted, where nothing would fire again; and a
  /// panel mounted by a STORED user lens (`_ownSelected` true from
  /// [initState]) must not steal focus and raise the keyboard on a sheet the
  /// user only opened to read.
  int _ownFocusTaps = 0;

  static bool _picksOwn(HandlerLensPick? pick) =>
      pick != null && pick.roleId == null && (pick.brief?.isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    final pick = widget.value.lens;
    _ownSelected = _picksOwn(pick);
    _ownController = TextEditingController(text: pick?.brief ?? '');
  }

  @override
  void didUpdateWidget(HandlerLensControl old) {
    super.didUpdateWidget(old);
    final pick = widget.value.lens;
    if (pick == old.value.lens) return;
    if (pick != null && pick.roleId != null) {
      // A real or unknown role id is unambiguous evidence the sixth chip is
      // not what is running.
      _ownSelected = false;
    } else if (_picksOwn(pick)) {
      _ownSelected = true;
      // Compared against what this field would COMMIT, never against the
      // previous external value. Under [HandlerLensControl.commitBriefOnEdit]
      // the host echoes back the JOINED form of the user's own keystroke, which
      // never equals the draft it came from once a second line exists — so
      // comparing the two external values rewrites their line breaks to "; "
      // under the cursor, one keystroke behind. Only a brief this field could
      // not have produced — the bridge having kept something else — is allowed
      // to land on the controller.
      if (pick!.brief != handlerJoinOwnLensLines(_ownController.text)) {
        _ownController.text = pick.brief!;
      }
    }
    // Else: roleId null with brief empty/null is ambiguous between "Nothing
    // extra" and "Your own" with an untyped draft — a local tap already
    // resolved that transition, so an external echo of it must not undo it.
  }

  @override
  void dispose() {
    _ownController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final catalog = ref.watch(agentCatalogProvider);
    // The tool that will actually run, which is what every claim below is about.
    final effectiveJudge = handlerEffectiveJudge(
      ref,
      widget.terminalId,
      widget.value.judgeTool,
    );
    final judgeCapable = effectiveJudge == null
        ? null
        : catalog[effectiveJudge]?.judgeCapable;
    final judgeLabel = effectiveJudge == null
        ? null
        : (catalog[effectiveJudge]?.label ?? effectiveJudge);
    // A judge that cannot go headless runs no decide pass at all — the bridge
    // gates the whole path on this same answer — so a lens here is stored and
    // does nothing until the judge picker changes.
    final parked = judgeCapable == false;
    // Presence is the capability signal: a machine that never named the lenses
    // it reads would strip a pick off the frame in silence, so the whole
    // control goes inert rather than take one.
    final advertised = ref.watch(handlerStateProvider).value?.lenses;
    final unreported = advertised == null;
    final pick = widget.value.lens;
    // A newer machine's lens. It is a real pick and stays in force untouched;
    // no chip in this row can name it, so none of them may paint as chosen.
    final unknownId =
        pick?.roleId != null && handlerLensFromWire(pick!.roleId) == null;

    // Only the intersection of what this build knows and what this machine
    // named, so a newer app can never send an id the far end would refuse.
    // "Your own" is unconditional: it is no wire role id, so nothing the bridge
    // advertised gates it.
    final offered = <(String, String?)>[
      for (final lens in HandlerLens.values)
        if (advertised?.contains(handlerLensToWire(lens)) ?? false)
          (handlerLensLabel(lens), handlerLensToWire(lens)),
      (handlerLensOwnLabel, _ownChipId),
    ];

    void selectPreset(String? id) {
      widget.onRoleTapped?.call();
      // The brief moves with the pick, so the host has to hear that control was
      // answered too. A host that collects rather than diffs (the arm sheet)
      // sends an untouched brief as null — "leave the stored one alone" — and
      // the bridge would then run this preset ON TOP of a user lens whose panel
      // this tap has just hidden, which is the one state §6 says cannot exist.
      widget.onBriefEdited?.call();
      setState(() => _ownSelected = false);
      widget.onChanged((
        judgeTool: widget.value.judgeTool,
        judgeModel: widget.value.judgeModel,
        // Every preset clears the brief: two stances cannot both run (§6), so
        // the draft rides only in [_ownController] until "Your own" comes
        // back.
        lens: (roleId: id, brief: ''),
      ));
    }

    void selectOwn() {
      widget.onRoleTapped?.call();
      setState(() {
        _ownSelected = true;
        _ownFocusTaps++;
      });
      widget.onChanged((
        judgeTool: widget.value.judgeTool,
        judgeModel: widget.value.judgeModel,
        lens: (
          roleId: null,
          brief: handlerJoinOwnLensLines(_ownController.text),
        ),
      ));
    }

    Widget chip(String label, String? id) {
      final isOwn = id == _ownChipId;
      final selected =
          !unreported &&
          (isOwn
              ? _ownSelected
              : !_ownSelected && pick != null && pick.roleId == id);
      return AbChip.choice(
        label: label,
        selected: selected,
        // The accent marks the one lens actually running. A parked chip keeps
        // the muted default with its fill: chosen, and not in effect.
        color: selected && !parked ? p.accent : null,
        enabled: !unreported,
        onTap: isOwn ? selectOwn : () => selectPreset(id),
      );
    }

    String? caption;
    // Whether "Takes effect on the next pass." may attach to [caption] — the
    // special-case captions below (unreported/parked/unset/unknown) never take
    // it, the precedence the "outranks" test pins.
    var nextPassEligible = false;
    if (unreported) {
      caption = handlerLensUnreportedBlurb;
    } else if (parked) {
      caption = handlerLensParkedBlurb;
    } else if (pick == null) {
      caption = handlerLensUnsetBlurb;
    } else if (_ownSelected) {
      nextPassEligible = true;
      caption = null; // the panel sits directly below and says it (§7)
    } else if (unknownId) {
      caption = handlerLensUnknownBlurb;
    } else {
      nextPassEligible = true;
      caption = pick.roleId == null
          // Nothing on top of the floor, which the line above already states —
          // and with no chip standing for it, no chip paints as chosen either.
          ? null
          : handlerLensBlurb(handlerLensFromWire(pick.roleId));
    }
    if (nextPassEligible && widget.appliesNextPass) {
      caption = caption == null
          ? 'Takes effect on the next pass.'
          : '$caption Takes effect on the next pass.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Head(label: 'What Handler weighs'),
        const Padding(
          padding: EdgeInsets.fromLTRB(
            AbTokens.space16,
            0,
            AbTokens.space16,
            AbTokens.space10,
          ),
          child: _FloorLine(),
        ),
        Padding(
          padding: _gutter,
          // Chips rather than a segmented control: the row is five stances —
          // the four presets and "Your own" — and none of
          // them fits a control built for two or three closed options.
          // [AbChip.choice] rather than [AbChip.toggle]: these labels are
          // phrases the user reads to decide with, not flag names they already
          // know, so they keep their casing and a size that can be read.
          child: Wrap(
            spacing: AbTokens.space6,
            runSpacing: AbTokens.space6,
            children: [for (final (label, id) in offered) chip(label, id)],
          ),
        ),
        if (caption != null) _Caption(text: caption),
        // This is the one class of surface where the warning is actionable;
        // everywhere else it appears it only diagnoses.
        if (parked) _Notice(text: handlerJudgeParkedNotice(judgeLabel)),
        if (_ownSelected)
          _OwnLensPanel(
            controller: _ownController,
            focusTaps: _ownFocusTaps,
            enabled: !unreported,
            commitOnEdit: widget.commitBriefOnEdit,
            onEdited: widget.onBriefEdited,
            onCommit: (raw) => widget.onChanged((
              judgeTool: widget.value.judgeTool,
              judgeModel: widget.value.judgeModel,
              lens: (roleId: null, brief: handlerJoinOwnLensLines(raw)),
            )),
          ),
      ],
    );
  }
}

/// Joins a multi-line draft into the one line the bridge actually stores.
/// `oneLine` (`bridge/src/handler/decision.ts`) collapses a bare newline to a
/// SPACE, so two rules typed on two lines would otherwise arrive as one fused,
/// grammatical, WRONG sentence (redesign spec §8). Joining with `"; "` here
/// keeps each line's boundary alive through that collapse; blank lines are
/// dropped so a stray Enter costs nothing.
String handlerJoinOwnLensLines(String raw) => raw
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('; ');

/// The permanent line under the section head — every session is judged on
/// this regardless of pick, so it is prose rather than another eyebrow:
/// a second [AbSectionHeader] here would rank as a sibling section instead of
/// a continuation of the one above it (redesign spec §7).
class _FloorLine extends StatelessWidget {
  const _FloorLine();

  @override
  Widget build(BuildContext context) => Text(
    "Always: your goal, and whether an item's evidence closes it. "
    'A lens adds one question:',
    style: AbTokens.sansStyle(
      fontSize: AbTokens.fontXs,
      color: context.antgrid.textSecondary,
    ),
  );
}

/// The user-authored stance: guidance, then the free-text field. Shown only
/// while "Your own" is the selected chip — every other chip hides this and
/// leaves [controller]'s draft untouched (redesign spec §6).
class _OwnLensPanel extends StatefulWidget {
  const _OwnLensPanel({
    required this.controller,
    required this.focusTaps,
    required this.enabled,
    required this.commitOnEdit,
    required this.onCommit,
    this.onEdited,
  });

  final TextEditingController controller;

  /// How many times the "Your own" chip has been tapped. Every increase —
  /// including the one that mounted this panel — puts the cursor in the field;
  /// see [_HandlerLensControlState._ownFocusTaps] for why it is a count.
  final int focusTaps;

  final bool enabled;

  /// See [HandlerLensControl.commitBriefOnEdit].
  final bool commitOnEdit;

  /// The raw, unjoined text as the field holds it — the caller applies the
  /// `"; "` join (redesign spec §8, [handlerJoinOwnLensLines]).
  final ValueChanged<String> onCommit;

  /// See [HandlerLensControl.onBriefEdited].
  final VoidCallback? onEdited;

  @override
  State<_OwnLensPanel> createState() => _OwnLensPanelState();
}

class _OwnLensPanelState extends State<_OwnLensPanel> {
  // Owned rather than passed in: focus is this panel's own ephemera, not part
  // of the draft that survives a preset switch — unlike [widget.controller].
  late final FocusNode _focusNode = FocusNode()..addListener(_onFocusChanged);

  @override
  void initState() {
    super.initState();
    // The tap that mounted this panel. Requesting on a node no [Focus] has
    // adopted yet is the supported order — [FocusNode] holds the request until
    // it is reparented, which is exactly what happens when this builds.
    if (widget.focusTaps > 0) _focusNode.requestFocus();
  }

  @override
  void didUpdateWidget(_OwnLensPanel old) {
    super.didUpdateWidget(old);
    // A second tap on the chip already showing: the panel never unmounted, so
    // this is the only thing left that can answer it.
    if (widget.focusTaps != old.focusTaps) _focusNode.requestFocus();
  }

  void _onFocusChanged() {
    // Losing focus is this multi-line field's "done": Enter has to insert a
    // line rather than submit, since the whole point is one rule per line.
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() => widget.onCommit(widget.controller.text);

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbTokens.space16,
      AbTokens.space10,
      AbTokens.space16,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AbTokens.space6),
          child: Text(
            // Carries the one-rule-per-line format, which the hint used to
            // teach by being three lines long. A hint cannot hold a format
            // rule: it is gone on the first keystroke, which is the moment the
            // rule starts to matter.
            'One rule per line. They can only make Handler stricter, never '
            'looser.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textSecondary,
            ),
          ),
        ),
        AbTextField(
          key: const ValueKey('handlerOwnLensField'),
          controller: widget.controller,
          focusNode: _focusNode,
          enabled: widget.enabled,
          minLines: 3,
          maxLines: 6,
          showClearButton: true,
          // One line, not three: a hint as tall as [minLines] fills the box,
          // so an empty field reads as one already written in. The register is
          // what one example still earns its place for — a rule is a short
          // lowercase condition, not a paragraph.
          hintText: 'not done until the tests pass',
          // The bridge clips a longer brief rather than refusing it, so this
          // is a courtesy bound and not a gate: it shows the user where the
          // prompt stops.
          inputFormatters: [
            LengthLimitingTextInputFormatter(handlerMaxBriefChars),
          ],
          onClear: () {
            widget.onEdited?.call();
            _commit();
          },
          onChanged: (_) {
            widget.onEdited?.call();
            if (widget.commitOnEdit) _commit();
          },
          onSubmitted: (_) {
            widget.onEdited?.call();
            _commit();
          },
        ),
      ],
    ),
  );
}

/// Which CLI judges the session's pauses, and under which model.
///
/// Split out from the lens so a host that already names the judge somewhere
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
              // The catalog's label, never the registry key — the menu below
              // names every tool that way, and a row naming the same tool by
              // its raw id reads as a different one.
              ? (defaultTool == null
                    ? 'Default'
                    : 'Default (${catalog[defaultTool]?.label ?? defaultTool})')
              : (catalog[value.judgeTool]?.label ?? value.judgeTool!),
          entries: [
            AbMenuItem(label: 'Default', value: ''),
            for (final tool in judgeTools)
              AbMenuItem(label: catalog[tool]?.label ?? tool, value: tool),
          ],
          onSelected: (picked) {
            final tool = picked.isEmpty ? null : picked;
            // Re-picking the tool already in force is not an edit. Firing
            // anyway would carry the cleared model into the delta and wipe an
            // override the user only opened the menu to read back.
            if (tool == value.judgeTool) return;
            onChanged((
              judgeTool: tool,
              // Cleared, never carried: a model id is a name only its own CLI
              // answers to, so keeping it across a tool change hands the new
              // judge a flag it rejects on every pass.
              judgeModel: null,
              lens: value.lens,
            ));
          },
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
            lens: value.lens,
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
    // A judge change resets the field unconditionally, even when the committed
    // model was null on both sides: an id typed but never submitted survives
    // that comparison, and the field would then offer the PREVIOUS CLI's id to
    // the new judge — the one thing clearing the model on a tool change exists
    // to prevent. Otherwise only when the value moved underneath us; never on
    // every rebuild, which would fight the user's cursor as they type.
    if (widget.judgeTool != old.judgeTool) {
      _controller.text = widget.model ?? '';
    } else if (widget.model != old.model &&
        (widget.model ?? '') != _controller.text) {
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
      // A model this catalog does not describe still names itself. The list is
      // whatever a CHAT session of that tool happened to report, so an id the
      // user typed on another surface — or one the bridge holds from a build
      // ago — is routinely absent from it, and rendering it as "Default" would
      // report a configured model as unset.
      value: selected?.name ?? widget.model ?? 'Default',
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
          onTap: () => detached('_PickerRow', 'open settings picker', () async {
            final anchor = abMenuAnchorRect(anchorContext);
            if (anchor == null) return;
            final picked = await showAbMenu<String>(
              context: anchorContext,
              anchorRect: anchor,
              entries: entries,
            );
            // The menu outlives this row — a project switch or a host restart
            // can tear the sheet down while it is up — and `onSelected` runs
            // `setState` on the sheet's State.
            if (picked != null && anchorContext.mounted) onSelected(picked);
          }),
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
///
/// One tint for every state it can carry. A live lens used to be muted, on the
/// reasoning that a working control needs no commentary — but this line is not
/// commentary: five chips reading PM, QA, CRITIC and the rest name roles and
/// nothing else, so what each one asks the agent exists ONLY here. Setting the
/// definition of the chosen option at the contrast floor is what made the row
/// undecidable without leaving the sheet.
class _Caption extends StatelessWidget {
  const _Caption({required this.text});

  final String text;

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
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontXs,
        color: context.antgrid.textSecondary,
      ),
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

/// Opens the settings sheet for an ARMED [terminalId] — the PA bar's lens chip
/// and the Handler tab's armed menu are its two doors, and both exist only
/// while the session is armed.
///
/// Every change commits on the spot as a `handler:configure` carrying `armed:
/// true`, which is the bridge's edit path: there is no Save. The one thing a
/// dismissal can strand is brief text typed and never submitted, which is
/// accepted over committing a judge pass per keystroke — the bridge's edit path
/// clears `lastJudgedContextHash` on every configure.
///
/// `armed: true` is an EDIT only while a session exists to edit. This sheet is
/// a modal and outlives the bar that opened it, so it closes itself rather than
/// commit into a session that disarmed underneath it — see [_SettingsSheetState._commit].
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
    if (!mounted) return;
    final service = focusedServiceOrNull(
      ref.container,
      (s) => s.handlerService,
    );
    // `armed: true` on an already-armed session is the bridge's EDIT path — but
    // sent once the session is GONE it is a fresh arm, which retires that
    // slot's undo offers and puts Handler back to judging work the user let
    // finish. Reachability is not the guarantee it looks like: this is a modal,
    // and the PA bar row that opened it vanishes the moment an autonomous
    // wrap-up or a dead PTY disarms the session underneath it.
    final stillArmed =
        ref.read(handlerStateProvider).value?.sessions[widget.terminalId] !=
        null;
    if (service == null || !stillArmed) {
      Navigator.of(context).maybePop();
      return;
    }
    final edit = handlerSessionSettingsEdit(_current, next);
    // An all-null delta is not a cheap send: the bridge's edit path clears
    // `lastJudgedContextHash` unconditionally, so a configure that changes
    // nothing still buys a fresh judge pass — a real LLM call — over an agent
    // that has not moved.
    if (edit.judgeTool == null &&
        edit.judgeModel == null &&
        edit.role == null &&
        edit.brief == null) {
      return;
    }
    // Pinned only once the send is real. A value pinned ahead of a dropped send
    // is one no status frame can correct — `_current` prefers `_value` — so
    // every later delta is computed against a `from` the bridge never held.
    service.arm(
      terminalId: widget.terminalId,
      judgeTool: edit.judgeTool,
      judgeModel: edit.judgeModel,
      role: edit.role,
      brief: edit.brief,
    );
    setState(() => _value = next);
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
