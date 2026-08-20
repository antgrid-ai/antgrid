import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../models/branch_remote_status.dart';
import '../../providers/new_session_picker.dart';

/// One line under the composer's context row when the branch this session
/// starts from has fallen behind its remote.
///
/// Advisory, never a gate: it states a fact and offers no action, Start stays
/// enabled throughout, and the whole line retires the moment a start is in
/// flight — a verdict that lands after the session launched has nothing left to
/// warn about and would only read as a failure. It also cannot fold into the
/// branch chip: the context row above is budgeted to exactly one line
/// (new_session_composer.dart), and counts in the chip label would eat the
/// branch name's width floor.
class BranchRemoteAdvisory extends ConsumerWidget {
  const BranchRemoteAdvisory({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(selectedTargetProjectProvider);
    final branch = ref.watch(newSessionEffectiveBranchProvider);
    final starting = ref.watch(newSessionStartInFlightProvider);

    BranchRemoteStatus? status;
    if (target != null && branch != null && !starting) {
      status = ref
          .watch(
            newSessionBranchRemoteStatusProvider((
              targetId: target.id,
              branch: branch,
            )),
          )
          // No loading state on purpose: a spinner for a check nobody asked for
          // is noise, and the answer is silence most of the time.
          .value;
    }

    final message = (status != null && status.isStaleBase)
        ? branchRemoteAdvisoryMessage(status)
        : null;

    // Animates rather than pops because the answer arrives seconds after the
    // row it sits under, often while the prompt field below already has focus.
    return AnimatedSize(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : _AdvisoryLine(message: message),
    );
  }
}

/// Counts only where they are real. `differs` means the remote commit is not an
/// object in this repo, so how far behind is unknowable without a fetch —
/// naming a number there would be an invention. A count the wire did not carry
/// is the same kind of unknown: [BranchRemoteStatus] parses whatever a newer or
/// older bridge sends, so every count is treated as absent until proven
/// present rather than defaulted to zero.
String branchRemoteAdvisoryMessage(BranchRemoteStatus s) {
  final remote = s.remoteRefLabel;
  final behind = s.behind;
  final ahead = s.ahead;
  String commits(int n) => n == 1 ? '1 commit' : '$n commits';
  return switch (s.state) {
    BranchRemoteState.behind when behind != null && behind > 0 =>
      '${s.branch} is ${commits(behind)} behind $remote',
    BranchRemoteState.diverged when behind != null && ahead != null =>
      '${s.branch} has diverged from $remote — $behind behind, $ahead ahead',
    BranchRemoteState.diverged => '${s.branch} has diverged from $remote',
    _ => '$remote has commits that are not in ${s.branch}',
  };
}

class _AdvisoryLine extends StatelessWidget {
  const _AdvisoryLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space10,
        AbTokens.space6,
        AbTokens.space10,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space2),
            child: AbIcon(
              AbIcons.warning,
              size: AbTokens.fontSm,
              color: p.warning,
            ),
          ),
          const SizedBox(width: AbTokens.space6),
          Expanded(
            child: Text(
              message,
              // Mono: this is git data — branch names and counts — not chrome.
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: p.textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
