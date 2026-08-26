import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo/demo_identity.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../providers/demo_mode.dart';
import '../providers/first_run.dart';
import '../utils/platform_utils.dart';

/// Latch newly-done steps and record completion, from build — via a microtask,
/// because provider state must never be written during build. Idempotent: the
/// notifier's own no-op guards make a double-fired microtask harmless.
void _latchAndMaybeComplete(WidgetRef ref, List<FirstRunStep> steps) {
  // The demo answers several of these steps with canned data — Recent lists
  // sample sessions, the picker lists a sample project — and the latch is
  // permanent. A reviewer who opens the sample project must not come back to a
  // checklist claiming they already started a session on a real machine.
  if (ref.read(demoModeProvider)) return;
  final state = ref.read(firstRunProvider);
  final newlyDone = {
    for (final s in steps)
      if (s.done && !state.completedSteps.contains(s.id)) s.id,
  };
  final allDone = steps.every((s) => s.done);
  if (newlyDone.isEmpty && !(allDone && !state.checklistCompleted)) return;
  // Capture the container, not ref: the microtask may outlive the widget
  // (same hazard as carrying a WidgetRef across an await — see app/CLAUDE.md).
  final container = ref.container;
  Future.microtask(() {
    final n = container.read(firstRunProvider.notifier);
    if (newlyDone.isNotEmpty) n.latchSteps(newlyDone);
    // markChecklistCompleted flips firstRunChecklistVisibleProvider false, so
    // the surface unmounts on the next frame — the "never re-show" persistence.
    if (allDone) n.markChecklistCompleted();
  });
}

/// One line per step, terminal-native: the mono `[x]`/`[ ]` marker is data,
/// not chrome. The first UNCHECKED step reads as a cursor (primary + medium
/// weight) without any tutorial prose; later unchecked steps recede.
class _FirstRunStepRow extends StatelessWidget {
  const _FirstRunStepRow({required this.step, required this.isCursor});

  final FirstRunStep step;

  /// True for the first unchecked step only.
  final bool isCursor;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    final Color labelColor;
    if (step.done) {
      labelColor = t.textMuted;
    } else {
      labelColor = isCursor ? t.textPrimary : t.textSecondary;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          step.done ? '[x]' : '[ ]',
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXs,
            color: step.done ? t.statusRunning : t.textMuted,
          ),
        ),
        const SizedBox(width: AbTokens.space8),
        Expanded(
          child: Text(
            step.label,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: labelColor,
              fontWeight: isCursor && !step.done
                  ? FontWeight.w500
                  : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }
}

/// Contextual one-liner for the FIRST unchecked desktop step. Sign-in gets
/// none — the sign-in screen owns that flow. Kept short enough to survive the
/// sidebar's ~244px of text width without turning into a paragraph.
String? _desktopHintFor(String? firstOpenStepId) => switch (firstOpenStepId) {
  // Names no surface on purpose: from the sidebar the nearest Open Folder
  // button is the drawer's own empty state, from New Session it is the
  // composer, and the hint cannot know which one the user is looking at.
  FirstRunStepIds.openProject => 'Open a folder to add your first project.',
  FirstRunStepIds.startSession => 'Pick a project, describe a task, hit send.',
  FirstRunStepIds.connectPhone =>
    'Sign in to Antgrid on your phone with this account.',
  FirstRunStepIds.armHandler =>
    'Click the shield in a session title bar — Handler replies while you are '
        'away.',
  _ => null,
};

/// Aligns the step markers under the header's TITLE rather than its chevron:
/// the drawer gutter plus [AbListRow]'s leading slot and the gap after it.
const _stepIndent =
    AbTokens.drawerGutter + AbTokens.drawerLeadingSlot + AbListRow.leadingGap;

/// Desktop setup checklist, docked in the sidebar directly above `UpdateRow`
/// and the account footer.
///
/// It belongs to the DRAWER, not the New Session canvas, because the drawer is
/// the only desktop surface mounted on both routes. Two of the five steps
/// ("Connect your phone", "Arm Handler on a session") are performed from inside
/// a session, where the canvas — and with it the checklist, its live signals
/// and its latch — did not exist: the old card was never on screen at the
/// moment its last steps became actionable.
///
/// Whether [FirstRunSetupSection] will render anything right now.
///
/// The section's own gate, hoisted so a host can also skip the chrome it would
/// otherwise wrap around nothing — the drawer's dock supplies a scroll view,
/// which would otherwise outlive the checklist by the whole life of the
/// install. Keep this as the single expression both sides read.
bool desktopSetupSectionVisible(WidgetRef ref) =>
    !isMobilePlatform &&
    // Its steps are about the user's own machine and its actions leave for
    // surfaces the demo has no account behind — including the button that
    // opens this very demo.
    !ref.watch(demoModeProvider) &&
    ref.watch(firstRunChecklistVisibleProvider);

/// Self-gates (mobile / dismissed / completed ⇒ shrink), so the call site stays
/// a single stable line — or [desktopSetupSectionVisible] where the host has
/// chrome of its own to skip.
class FirstRunSetupSection extends ConsumerWidget {
  const FirstRunSetupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!desktopSetupSectionVisible(ref)) return const SizedBox.shrink();
    final steps = ref.watch(desktopFirstRunStepsProvider);
    _latchAndMaybeComplete(ref, steps);
    final t = context.antgrid;
    final collapsed = ref.watch(
      firstRunProvider.select((s) => s.checklistCollapsed),
    );
    final doneCount = steps.where((s) => s.done).length;
    final firstOpen = steps.firstWhereOrNull((s) => !s.done);
    final hint = _desktopHintFor(firstOpen?.id);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.drawerGutter,
            ),
            child: AbListRow(
              horizontalPadding: 0,
              density: AbRowDensity.sm,
              // No `hoverable`: a full-width fill on a docked header reads as a
              // slab, not a row. The pointer cursor and the chevron are the
              // affordance — this is chrome, not a list row to be picked out of
              // its neighbours.
              leading: AbDisclosureChevron(expanded: !collapsed),
              // Same treatment as the drawer's PROJECTS label — this is the
              // second group header in one column, and a section header is
              // chrome, so sans (see the font rule in app/CLAUDE.md).
              title: Text(
                'SETUP · $doneCount/${steps.length}',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                  color: t.textMuted,
                ),
              ),
              trailing: AbIconButton(
                icon: AbIcons.close,
                tone: AbIconButtonTone.muted,
                tooltip: "Dismiss — won't show again",
                onTap: () =>
                    ref.read(firstRunProvider.notifier).dismissChecklist(),
              ),
              onTap: () => ref
                  .read(firstRunProvider.notifier)
                  .toggleChecklistCollapsed(),
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _stepIndent,
                0,
                AbTokens.drawerGutter,
                AbTokens.space8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < steps.length; i++) ...[
                    if (i > 0) const SizedBox(height: AbTokens.space6),
                    // Compare ids, not references: record identity is
                    // unspecified in Dart (a record can be re-boxed between
                    // reads).
                    _FirstRunStepRow(
                      step: steps[i],
                      isCursor: steps[i].id == firstOpen?.id,
                    ),
                  ],
                  if (hint != null) ...[
                    const SizedBox(height: AbTokens.space8),
                    Text(
                      hint,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: t.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Mobile first-run checklist — fills the Recent canvas's empty slot until the
/// three steps that make the rest of the UI exist are done (or the user
/// dismisses it). Successor to the static connect-machine guide: same centered
/// skeleton, but the rows check themselves off from live signals.
///
/// Stays on the canvas rather than following the desktop checklist into the
/// drawer: on mobile that drawer is a slide-in behind a hamburger, and
/// onboarding a user has to go looking for is not onboarding.
class MobileFirstRunChecklist extends ConsumerWidget {
  const MobileFirstRunChecklist({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(mobileFirstRunStepsProvider);
    _latchAndMaybeComplete(ref, steps);
    final t = context.antgrid;
    final firstOpen = steps.firstWhereOrNull((s) => !s.done);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AbTokens.space24),
        child: ConstrainedBox(
          // Keeps step lines readable on tablets; no-op on phone widths.
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbIcon(AbIcons.server, size: 32, color: t.textDisabled),
              const SizedBox(height: AbTokens.space12),
              Row(
                children: [
                  // Balance the trailing dismiss button so the title stays
                  // visually centered under the icon.
                  const SizedBox(width: AbTokens.iconButtonBox),
                  Expanded(
                    child: Text(
                      // Not "No machines yet": a machine may exist
                      // mid-checklist (steps 2–3 still open).
                      'Connect a machine',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontSm,
                        color: t.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.close,
                    tooltip: "Dismiss — won't show again",
                    onTap: () =>
                        ref.read(firstRunProvider.notifier).dismissChecklist(),
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space14),
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0) const SizedBox(height: AbTokens.space8),
                _FirstRunStepRow(
                  step: steps[i],
                  isCursor: steps[i].id == firstOpen?.id,
                ),
              ],
              const SizedBox(height: AbTokens.space14),
              Text(
                // Load-bearing: pull-to-refresh is what re-pulls the machine
                // inventory (step 1) and dials the picker-viewed machine so
                // its project advert lands (step 2).
                "Pull down to refresh once you've done a step.",
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: t.textMuted,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AbTokens.space16),
              // Every step above needs a desktop the user may not be near. This
              // is the one thing they can do from the phone alone, so the app
              // is never a dead end while the checklist is open.
              AbButton(
                label: kDemoEntryLabel,
                onTap: () => enterDemoMode(ref.container),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
