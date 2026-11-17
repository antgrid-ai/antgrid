import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/git_branch.dart';
import '../../providers/new_session_picker.dart';
import '../ab_status_helpers.dart' show caughtErrorCopy;

/// A combo box has no intrinsic width, so the chip picks one: wide enough for
/// a typical branch name, never wider than the slot it is given.
const double _fieldWidth = CarbonSpacing.spacing13 + CarbonSpacing.spacing09;

/// Branch picker for the New Session composer: a searchable combo box over the
/// selected project's branches.
class BranchChip extends ConsumerStatefulWidget {
  const BranchChip({super.key, this.enabled = true});

  /// See [EnvironmentChip.enabled] — the composer owns the frozen state. This
  /// is not the same as the `catalogUsable` check below, which only reflects a
  /// branch catalog there is nothing to choose from.
  final bool enabled;

  @override
  ConsumerState<BranchChip> createState() => _BranchChipState();
}

class _BranchChipState extends ConsumerState<BranchChip> {
  final FocusNode _focus = FocusNode();
  bool _hadFocus = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  // Branches change underneath the composer (checkouts, fetches), so entering
  // the field re-reads them rather than showing what was true at mount.
  void _onFocus() {
    final focused = _focus.hasFocus;
    if (focused && !_hadFocus) {
      ref.invalidate(newSessionBranchCatalogProvider);
    }
    _hadFocus = focused;
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(selectedTargetProjectProvider);
    if (target == null) return const SizedBox.shrink();

    final catalogAsync = ref.watch(newSessionBranchCatalogProvider);
    final effective = ref.watch(newSessionEffectiveBranchProvider);
    final isolated = ref.watch(newSessionIsolatedProvider);

    var placeholder = 'Loading branches...';
    var catalogUsable = false;
    var loading = true;
    String? listError;
    var options = <CarbonOption<String>>[];
    String? value;

    // Error BEFORE the value: Riverpod retains the previous catalog alongside
    // an error, and a stale list must not pass for the current one.
    if (catalogAsync.hasError) {
      placeholder = 'Branches unavailable';
      loading = false;
      catalogUsable = true;
      listError = caughtErrorCopy(
        catalogAsync.error!,
        'Try again in a moment.',
      );
    } else if (catalogAsync.hasValue) {
      loading = false;
      final catalog = catalogAsync.value;
      if (catalog == null) {
        placeholder = 'Branches unavailable';
      } else if (!catalog.isRepository) {
        placeholder = 'No Git repository';
      } else {
        catalogUsable = true;
        final current = catalog.current;
        // Resolved centrally so the chip and the remote advisory below it can
        // never name different branches.
        placeholder = effective == null
            ? 'Detached HEAD'
            : (isolated ? 'Base: $effective' : effective);
        if (effective != null && catalog.branches.contains(effective)) {
          value = effective;
        }
        // Current branch first, the rest case-insensitively with an exact
        // tie-breaker.
        final sorted = [...catalog.branches]
          ..sort((a, b) {
            if (a == current) return -1;
            if (b == current) return 1;
            final cmp = a.toLowerCase().compareTo(b.toLowerCase());
            return cmp != 0 ? cmp : a.compareTo(b);
          });
        options = [
          for (final b in sorted)
            CarbonOption(
              value: b,
              label: isolated ? 'Base: $b' : b,
              description: b == current ? 'Current' : null,
            ),
        ];
      }
    }

    void pick(String branch) =>
        ref
            .read(newSessionBranchSelectionProvider.notifier)
            .set(
              NewSessionBranchSelection(targetId: target.id, branch: branch),
            );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth < _fieldWidth
                  ? constraints.maxWidth
                  : _fieldWidth
            : _fieldWidth;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          child: SizedBox(
            width: width,
            child: CarbonComboBox<String>(
              options: options,
              value: value,
              onChanged: widget.enabled && catalogUsable ? pick : null,
              focusNode: _focus,
              placeholder: placeholder,
              semanticLabel: 'Branch',
              loading: loading,
              listErrorText: listError,
              emptyText: 'No matching branches',
              // The prefix is context, not part of the name: typing "main"
              // must still find "Base: main".
              filter: (o, q) => o.value.toLowerCase().contains(q.toLowerCase()),
              listMinWidth: 288,
              listMaxWidth: 480,
              preferAbove: true,
            ),
          ),
        );
      },
    );
  }
}
