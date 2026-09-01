import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../models/session_entry.dart';
import '../providers/session_setup.dart';
import 'transcript/format.dart';

/// How much of the provisioning pane the ledger may take before it scrolls.
/// A `worktree.setup` block is a list a human wrote, so it is short in
/// practice — but nothing bounds it, and the transcript underneath is the
/// thing the user is actually watching.
const double _kLedgerMaxViewportFraction = 0.35;

/// How long the run has been going, ticking once a second.
///
/// Its own widget purely for the ticker: a rebuild every second is cheap here
/// and ruinous one level up, where it would reach the live terminal beside it.
///
/// [startedAt] is the BRIDGE's clock, and for a remote machine that is not
/// ours. A reading that comes out negative is the one shape of skew we can
/// actually detect, and it is answered by saying nothing — an elapsed time is
/// orientation, and a wrong one is worse than none.
class SetupElapsed extends StatefulWidget {
  const SetupElapsed({super.key, required this.startedAt, required this.color});

  final int startedAt;
  final Color color;

  @override
  State<SetupElapsed> createState() => _SetupElapsedState();
}

class _SetupElapsedState extends State<SetupElapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    if (startedAt <= 0) return const SizedBox.shrink();
    final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
    if (elapsed < 0) return const SizedBox.shrink();
    return Text(
      // The app's one elapsed format, shared with the agent transcript's own
      // "Working for 2m 35s" directly below this strip — two live readouts of
      // the same seconds must not disagree about how to spell them.
      formatDuration(Duration(milliseconds: elapsed)),
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontXxs,
        color: widget.color,
      ),
    );
  }
}

/// The run's steps, done through pending.
///
/// "2 of 5" says how far along the run is and nothing about what is left, which
/// on a real block is the question being asked — one 10 ms `copy:` ahead of
/// four minutes of installs reads as 20% done and is not.
///
/// Renders nothing without names: a state recovered from disk knows how many
/// steps ran but not what they were called, and so does a bridge that predates
/// the field. A ledger of blanks answers less than the progress rule already
/// above it.
class SetupStepLedger extends StatelessWidget {
  const SetupStepLedger({super.key, required this.setup});

  final SessionSetup setup;

  @override
  Widget build(BuildContext context) {
    final names = setup.stepNames;
    if (names.isEmpty) return const SizedBox.shrink();
    final colors = context.antgrid;
    final phase = sessionSetupPhase(setup);
    final current = setup.stepIndex;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgElevated,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      constraints: BoxConstraints(
        maxHeight:
            MediaQuery.sizeOf(context).height * _kLedgerMaxViewportFraction,
      ),
      width: double.infinity,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < names.length; i++)
              _StepRow(
                name: names[i],
                state: _stateOf(i, current, phase),
                colors: colors,
              ),
          ],
        ),
      ),
    );
  }

  _StepState _stateOf(int index, int current, SessionSetupPhase phase) {
    if (index < current) return _StepState.done;
    if (index > current) return _StepState.pending;
    // The current step is wherever the run stopped, so a settled run reports
    // its outcome on that row rather than leaving it looking still in flight.
    return switch (phase) {
      SessionSetupPhase.done => _StepState.done,
      SessionSetupPhase.failed => _StepState.failed,
      SessionSetupPhase.skipped ||
      SessionSetupPhase.interrupted => _StepState.pending,
      _ => _StepState.current,
    };
  }
}

enum _StepState { done, current, pending, failed }

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.name,
    required this.state,
    required this.colors,
  });

  final String name;
  final _StepState state;
  final AbColors colors;

  @override
  Widget build(BuildContext context) {
    final (icon, iconColor, textColor) = switch (state) {
      _StepState.done => (AbIcons.check, colors.success, colors.textMuted),
      _StepState.current => (
        AbIcons.chevronRight,
        colors.accent,
        colors.textPrimary,
      ),
      _StepState.failed => (AbIcons.error, colors.error, colors.textPrimary),
      _StepState.pending => (
        AbIcons.circle,
        colors.textDisabled,
        colors.textDisabled,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space2),
      child: Row(
        children: [
          AbIcon(icon, size: AbTokens.fontSm, color: iconColor),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
