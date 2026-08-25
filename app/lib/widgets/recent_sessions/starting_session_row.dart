import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_loading.dart';
import '../../providers/new_session_start.dart';

/// Finds the row while a start is in flight; absent when idle.
const Key startingSessionRowKey = Key('starting-session-row');

/// The phase copy, where a real Recent row prints its timestamp.
const Key startingSessionPhaseKey = Key('starting-session-phase');

/// Side of the leading glyph box, and the project line's indent under the
/// title on mobile — both mirror `recent_session_row_widget.dart` so this row
/// and the real one it becomes share a name column.
const double _leadingSize = 18;
const double _mobileProjectIndent = _leadingSize + AbTokens.space12;

/// The real row's project column width, so the project text wraps and
/// ellipsizes at the same point either side of the moment the session lands.
const double _railProjectWidth = 220;

/// Width of the slot the phase copy occupies, where a real row puts its time.
/// Fixed, and wider than that time slot: the copy changes length as the start
/// advances, and a slot that sized to it would resize the title column on
/// every phase.
///
/// Being wider is why the project column sits further left here than on the
/// real row — the columns share a width, not an x. Matching the time slot
/// instead would buy that alignment for one frame at the cost of truncating
/// every phase name for the whole start.
const double _railPhaseWidth = 150;

/// The session being started right now, standing in for the Recent row it will
/// become.
///
/// Renders nothing when no start is in flight, so both of the Recent tab's
/// branches mount it unconditionally — including the empty-recents one, which
/// is the first session a user ever starts and the moment this row matters
/// most.
///
/// Existing only here — not as a synthetic entry in the cache — keeps a
/// session that does not exist yet out of grouping, the per-row status map, the
/// summary counts and search.
///
/// Read-only and not tappable: there is nothing to open yet, and the composer
/// owns the single Stop affordance.
class StartingSessionRow extends ConsumerWidget {
  const StartingSessionRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(newSessionStartProgressProvider);
    if (progress == null) return const SizedBox.shrink();

    final isMobile = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    return Padding(
      key: startingSessionRowKey,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Same fallback width as the real row: below it the desktop rail's
          // fixed project + phase columns no longer fit beside a name.
          final compact = isMobile || constraints.maxWidth < 560;
          return compact
              ? _MobileLayout(progress: progress)
              : _DesktopLayout(progress: progress);
        },
      ),
    );
  }
}

class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({required this.progress});

  final NewSessionStartProgress progress;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _StartingMark(),
        const SizedBox(width: AbTokens.space12),
        Expanded(
          child: Row(
            children: [
              Flexible(child: _SessionTitle(title: progress.title)),
              const _StartingBadge(),
              const SizedBox(width: AbTokens.space12),
            ],
          ),
        ),
        SizedBox(
          width: _railProjectWidth,
          child: _ProjectLabel(name: _projectDisplayText(progress)),
        ),
        const SizedBox(width: AbTokens.space12),
        SizedBox(
          width: _railPhaseWidth,
          child: _PhaseLabel(label: phaseLabel(progress)),
        ),
      ],
    );
  }
}

class _MobileLayout extends StatelessWidget {
  const _MobileLayout({required this.progress});

  final NewSessionStartProgress progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const _StartingMark(),
            const SizedBox(width: AbTokens.space12),
            Expanded(child: _SessionTitle(title: progress.title)),
            const _StartingBadge(),
            const SizedBox(width: AbTokens.space8),
            // Capped rather than fixed: a phone has no room to reserve the
            // rail's full slot, and the title is the line that may give.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _railPhaseWidth),
              child: _PhaseLabel(label: phaseLabel(progress)),
            ),
          ],
        ),
        const SizedBox(height: AbTokens.space2),
        Padding(
          padding: const EdgeInsets.only(left: _mobileProjectIndent),
          child: _ProjectLabel(name: _projectDisplayText(progress)),
        ),
      ],
    );
  }
}

/// The leading slot, centred in the same box as every other row's glyph so the
/// name column keeps starting at the same x.
///
/// Muted rather than [AbLoadingDot]'s accent default: the rows below carry real
/// accent status marks, and the composer's dot for this same start is muted
/// too — one operation must not pulse in two colours on one screen.
class _StartingMark extends StatelessWidget {
  const _StartingMark();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: _leadingSize,
      child: Center(
        child: AbLoadingDot(
          size: AbTokens.dotSizeMd,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}

/// Shaped like `SessionDeletingBadge`: neutral, not an accent or an error
/// colour, because this is a normal operation in progress. Owns its leading
/// gap so the title measures against the badge, not against reserved space.
class _StartingBadge extends StatelessWidget {
  const _StartingBadge();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: AbTokens.space6),
      child: AbChip.system(label: 'STARTING'),
    );
  }
}

class _SessionTitle extends StatelessWidget {
  const _SessionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final text = title.trim();
    return Text(
      // A start carries either a session name or the leading prompt text; the
      // fallback only covers a title that is all whitespace.
      text.isEmpty ? 'New session' : text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontMd,
        color: context.antgrid.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Device-prefixed like the real row — a remote start must still say which
/// machine it is waking. An empty [NewSessionStartProgress.deviceName] is the
/// local target.
String _projectDisplayText(NewSessionStartProgress progress) {
  if (progress.deviceName.isEmpty) return progress.targetName;
  return '${progress.deviceName} · ${progress.targetName}';
}

class _ProjectLabel extends StatelessWidget {
  const _ProjectLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontSm,
        color: context.antgrid.textMuted,
      ),
    );
  }
}

/// Sans, unlike the mono timestamp it stands in for: this is chrome prose
/// about what the machine is doing, not row data.
class _PhaseLabel extends StatelessWidget {
  const _PhaseLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      key: startingSessionPhaseKey,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontXs,
        color: context.antgrid.textMuted,
      ),
    );
  }
}
