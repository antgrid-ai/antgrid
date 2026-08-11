import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_separator.dart';
import '../providers/session_search.dart';
import 'session_search_results.dart';

/// The MOBILE session search: an icon in the canvas's top bar that opens a
/// full-screen search modal.
///
/// Not the desktop's inline field with a hanging popup, which is a pointer
/// pattern. On a phone an always-open text box costs a whole row of a screen
/// that has none to spare, and a popup anchored under it can only show a few
/// rows before the keyboard takes the rest. Both Material and iOS answer this
/// the same way — a search icon in the navigation bar that expands into a
/// dedicated full-screen surface — so that is what this is: the query and its
/// results own the screen while the search is open, and nothing else competes
/// for the space.
class SessionSearchButton extends StatelessWidget {
  const SessionSearchButton({super.key});

  @override
  Widget build(BuildContext context) {
    return AbIconButton(
      icon: AbIcons.search,
      tooltip: 'Search sessions',
      onTap: () => showSessionSearch(context),
    );
  }
}

/// Opens the full-screen session search. Returns when it is dismissed.
///
/// A dialog route rather than an overlay, so the Android back button and the
/// system back gesture close it for free — an overlay would swallow neither and
/// would let back walk out of the whole route underneath instead.
Future<void> showSessionSearch(BuildContext context) {
  return showDialog<void>(
    context: context,
    // The modal draws its own safe-area padding: the results list must run to
    // the bottom edge under the gesture bar, not stop short of it.
    useSafeArea: false,
    builder: (_) => const _SessionSearchModal(),
  );
}

class _SessionSearchModal extends ConsumerStatefulWidget {
  const _SessionSearchModal();

  @override
  ConsumerState<_SessionSearchModal> createState() =>
      _SessionSearchModalState();
}

class _SessionSearchModalState extends ConsumerState<_SessionSearchModal> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(sessionSearchQueryProvider),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _set(String query) =>
      ref.read(sessionSearchQueryProvider.notifier).set(query);

  /// Clears the query on the way out. The modal is a transient surface — unlike
  /// the desktop field, which stays on screen holding its query, there is
  /// nothing left to show a stale one, so reopening starts fresh.
  void _close() {
    _set('');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    return Dialog.fullscreen(
      backgroundColor: t.bgDeepest,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AbTokens.space12),
              child: Row(
                children: [
                  Expanded(
                    child: AbSearchField(
                      controller: _controller,
                      hint: 'Search sessions…',
                      // The modal exists only to be typed into, so it opens
                      // with the keyboard already up.
                      autofocus: true,
                      height: AbTokens.rowHeightLg,
                      // No debounce: filtering is a local pass over the session
                      // cache, so a keystroke costs a rebuild, not a round trip.
                      debounce: null,
                      onChanged: _set,
                      onClear: () => _set(''),
                    ),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  AbIconButton(
                    icon: AbIcons.close,
                    tooltip: 'Close search',
                    onTap: _close,
                  ),
                ],
              ),
            ),
            const AbSeparator.horizontal(),
            Expanded(
              child: SessionSearchResults(
                // Straight to the session, then out of the way — the modal has
                // nothing to say once a row is taken.
                onOpened: _close,
                surfaceColor: t.bgDeepest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
