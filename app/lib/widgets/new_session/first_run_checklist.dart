import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../providers/first_run.dart';
import '../../utils/platform_utils.dart';

/// Latch newly-done steps and record completion, from build — via a microtask,
/// because provider state must never be written during build. Idempotent: the
/// notifier's own no-op guards make a double-fired microtask harmless.
void _latchAndMaybeComplete(WidgetRef ref, List<FirstRunStep> steps) {
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
    // the card unmounts on the next frame — the "never re-show" persistence.
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
/// none — the sign-in screen owns that flow.
String? _desktopHintFor(String? firstOpenStepId) => switch (firstOpenStepId) {
  FirstRunStepIds.openProject => 'Open a folder from the composer below.',
  FirstRunStepIds.startSession => 'Pick a project, describe a task, hit send.',
  FirstRunStepIds.connectPhone =>
    'Sign in to Antgrid on your phone with this account.',
  _ => null,
};

/// Desktop first-run checklist card, mounted unconditionally on the New
/// Session canvas — it self-gates (mobile / dismissed / completed ⇒ shrink),
/// so the call site stays a single stable line.
class FirstRunChecklistCard extends ConsumerWidget {
  const FirstRunChecklistCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isMobilePlatform) return const SizedBox.shrink();
    if (!ref.watch(firstRunChecklistVisibleProvider)) {
      return const SizedBox.shrink();
    }
    final steps = ref.watch(desktopFirstRunStepsProvider);
    _latchAndMaybeComplete(ref, steps);
    final t = context.antgrid;
    final doneCount = steps.where((s) => s.done).length;
    final firstOpen = steps.firstWhereOrNull((s) => !s.done);
    final hint = _desktopHintFor(firstOpen?.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.all(AbTokens.space12),
        decoration: BoxDecoration(
          color: t.bgSurface,
          border: Border.all(color: t.borderSubtle),
          borderRadius: BorderRadius.circular(AbTokens.radius8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'SETUP · $doneCount/${steps.length}',
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      letterSpacing: 0.66,
                      color: t.textMuted,
                    ),
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
            const SizedBox(height: AbTokens.space8),
            for (final s in steps) ...[
              // Compare ids, not references: record identity is unspecified in
              // Dart (a record can be re-boxed between reads).
              _FirstRunStepRow(step: s, isCursor: s.id == firstOpen?.id),
              const SizedBox(height: AbTokens.space6),
            ],
            if (hint != null)
              Text(
                hint,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: t.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mobile first-run checklist — fills the Recent canvas's empty slot until the
/// three steps that make the rest of the UI exist are done (or the user
/// dismisses it). Successor to the static connect-machine guide: same centered
/// skeleton, but the rows check themselves off from live signals.
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
            ],
          ),
        ),
      ),
    );
  }
}
