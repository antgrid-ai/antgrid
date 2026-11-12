import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../providers/new_session_start.dart';
import 'recent_session_row_actions.dart' show kRecentRailMinWidth;

/// Finds the row while a start is in flight; absent when idle.
const Key startingSessionRowKey = Key('starting-session-row');

/// The phase copy, where a real Recent row prints its timestamp.
const Key startingSessionPhaseKey = Key('starting-session-phase');

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
/// owns the single Stop affordance. It is a contained-list row with no
/// `onPressed`, which makes it static: no focus stop, announced as one node.
class StartingSessionRow extends ConsumerWidget {
  const StartingSessionRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(newSessionStartProgressProvider);
    if (progress == null) return const SizedBox.shrink();

    final isMobile = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final projectText = _projectDisplayText(progress);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Measured like the real rows, on the outer width, so the placeholder
        // never changes shape when the session it stands for lands.
        final compact =
            isMobile || constraints.maxWidth < kRecentRailMinWidth;
        return KeyedSubtree(
          key: startingSessionRowKey,
          child: CarbonContainedListRow(
            title:
                '${_titleText(progress.title)}, starting, $projectText, '
                '${phaseLabel(progress)}',
            leading: const _StartingMark(),
            content: compact
                ? _MobileLayout(progress: progress)
                : _DesktopLayout(progress: progress),
          ),
        );
      },
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
        Expanded(
          child: Row(
            children: [
              Flexible(child: _SessionTitle(title: progress.title)),
              const _StartingBadge(),
              const SizedBox(width: CarbonSpacing.spacing04),
            ],
          ),
        ),
        SizedBox(
          width: _railProjectWidth,
          child: _ProjectLabel(name: _projectDisplayText(progress)),
        ),
        const SizedBox(width: CarbonSpacing.spacing04),
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
            Expanded(child: _SessionTitle(title: progress.title)),
            const _StartingBadge(),
            const SizedBox(width: CarbonSpacing.spacing03),
            // Capped rather than fixed: a phone has no room to reserve the
            // rail's full slot, and the title is the line that may give.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _railPhaseWidth),
              child: _PhaseLabel(label: phaseLabel(progress)),
            ),
          ],
        ),
        const SizedBox(height: CarbonSpacing.spacing01),
        _ProjectLabel(name: _projectDisplayText(progress)),
      ],
    );
  }
}

/// The leading slot, centred in the same box as every other row's glyph so the
/// name column keeps starting at the same x.
///
/// Muted rather than the spinner's default: the rows below carry real status
/// glyphs in colour, and the composer's indicator for this same start is muted
/// too — one operation must not read in two colours on one screen.
class _StartingMark extends StatelessWidget {
  const _StartingMark();

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return SizedBox.square(
      dimension: t.iconSize,
      child: Center(
        child: CarbonSpinner(size: t.iconSize, color: t.colors.iconSecondary),
      ),
    );
  }
}

/// Shaped like the deleting badge: neutral, not an accent or an error colour,
/// because this is a normal operation in progress. Owns its leading gap so the
/// title measures against the badge, not against reserved space.
class _StartingBadge extends StatelessWidget {
  const _StartingBadge();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsetsDirectional.only(start: CarbonSpacing.spacing03),
      child: CarbonTag(
        label: 'Starting',
        size: CarbonTagSize.small,
        color: CarbonTagColor.gray,
      ),
    );
  }
}

/// A start carries either a session name or the leading prompt text; the
/// fallback only covers a title that is all whitespace.
String _titleText(String title) {
  final text = title.trim();
  return text.isEmpty ? 'New session' : text;
}

class _SessionTitle extends StatelessWidget {
  const _SessionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      _titleText(title),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.heading.copyWith(color: t.colors.textPrimary),
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
    final t = CarbonTheme.of(context);
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.code.copyWith(color: t.colors.textSecondary),
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
    final t = CarbonTheme.of(context);
    return Text(
      label,
      key: startingSessionPhaseKey,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.helper.copyWith(color: t.colors.textSecondary),
    );
  }
}
