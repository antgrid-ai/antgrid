import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/new_session_start.dart';

/// Finds the row while a start is in flight; absent when idle.
const Key startingSessionRowKey = Key('starting-session-row');

/// The phase copy, where a real Recent row prints its timestamp.
const Key startingSessionPhaseKey = Key('starting-session-phase');

/// Cap on the phase copy's width. The copy changes length as the start
/// advances; the title is the part that gives, so the line never reflows from
/// one phase to the next.
const double _phaseMaxWidth = 150;

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

    final projectText = _projectDisplayText(progress);
    return KeyedSubtree(
      key: startingSessionRowKey,
      child: CarbonContainedListRow(
        title:
            '${_titleText(progress.title)}, starting, $projectText, '
            '${phaseLabel(progress)}',
        leading: const _StartingMark(),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: CarbonSpacing.spacing01,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _SessionTitle(title: progress.title),
                      const _StartingBadge(),
                    ],
                  ),
                ),
                const SizedBox(width: CarbonSpacing.spacing03),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _phaseMaxWidth),
                  child: _PhaseLabel(label: phaseLabel(progress)),
                ),
              ],
            ),
            _OriginLabel(text: projectText),
          ],
        ),
      ),
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

class _OriginLabel extends StatelessWidget {
  const _OriginLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.label.copyWith(color: t.colors.textSecondary),
    );
  }
}

/// Stands in for the time a real row prints there: chrome prose about what the
/// machine is doing, in the same style.
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
      style: t.typography.label.copyWith(color: t.colors.textSecondary),
    );
  }
}
