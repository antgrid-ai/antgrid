import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/git_branch.dart';
import '../../providers/new_session_picker.dart';
import 'environment_menu.dart';

class BranchChip extends ConsumerWidget {
  const BranchChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(selectedTargetProjectProvider);
    if (target == null) return const SizedBox.shrink();

    final catalogAsync = ref.watch(newSessionBranchCatalogProvider);
    final selection = ref.watch(newSessionBranchSelectionProvider);

    String label = 'Loading branches...';
    bool disabled = false;

    catalogAsync.when(
      data: (catalog) {
        if (catalog == null) {
          label = 'Branches unavailable';
          disabled = true;
        } else if (!catalog.isRepository) {
          label = 'No Git repository';
          disabled = true;
        } else {
          final isExplicitValid = selection != null &&
              selection.targetId == target.id &&
              catalog.branches.contains(selection.branch);
          if (isExplicitValid) {
            label = selection.branch;
          } else if (catalog.current != null) {
            label = catalog.current!;
          } else {
            label = 'Detached HEAD';
          }
        }
      },
      error: (err, _) {
        label = 'Branches unavailable';
      },
      loading: () {
        label = 'Loading branches...';
      },
    );

    return ComposerChip(
      icon: AbIcons.gitBranch,
      label: label,
      onTap: (ctx) {
        if (disabled) return;
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        ref.invalidate(newSessionBranchCatalogProvider);
        showAbPanel<void>(
          context: ctx,
          anchorRect: anchor,
          preferred: AbMenuPlacement.above,
          builder: (_) => const BranchPanel(),
        );
      },
    );
  }
}

class BranchPanel extends ConsumerStatefulWidget {
  const BranchPanel({super.key});

  @override
  ConsumerState<BranchPanel> createState() => _BranchPanelState();
}

class _BranchPanelState extends ConsumerState<BranchPanel> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onQueryChanged);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {
      _query = _searchController.text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final target = ref.watch(selectedTargetProjectProvider);
    if (target == null) return const PanelHint('No project selected');

    final catalogAsync = ref.watch(newSessionBranchCatalogProvider);
    final selection = ref.watch(newSessionBranchSelectionProvider);

    return catalogAsync.when(
      data: (catalog) {
        if (catalog == null) {
          return const PanelHint('Branches unavailable. Bridge update required.');
        }
        if (!catalog.isRepository) {
          return const PanelHint('No Git repository in this folder');
        }

        final currentBranch = catalog.current;
        final explicitBranch = (selection != null &&
                selection.targetId == target.id &&
                catalog.branches.contains(selection.branch))
            ? selection.branch
            : null;
        final activeBranch = explicitBranch ?? currentBranch;

        final queryTrimmed = _query.trim().toLowerCase();
        final filtered = catalog.branches.where((b) {
          if (queryTrimmed.isEmpty) return true;
          return b.toLowerCase().contains(queryTrimmed);
        }).toList();

        // Sort: current branch first, remainder case-insensitively with exact tie-breaker
        filtered.sort((a, b) {
          if (a == currentBranch) return -1;
          if (b == currentBranch) return 1;
          final cmp = a.toLowerCase().compareTo(b.toLowerCase());
          if (cmp != 0) return cmp;
          return a.compareTo(b);
        });

        return SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(AbTokens.space8),
                child: AbTextField(
                  controller: _searchController,
                  focusNode: _focusNode,
                  autofocus: true,
                  hintText: 'Search branches…',
                  prefixIcon: AbIcons.search,
                ),
              ),
              Divider(height: 1, color: p.borderDefault),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(AbTokens.space12),
                        child: PanelHint('No matching branches'),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (ctx, index) {
                          final branch = filtered[index];
                          final isSelected = branch == activeBranch;
                          final isCurrent = branch == currentBranch;

                          return PanelRow(
                            icon: AbIcons.gitBranch,
                            label: branch,
                            selected: isSelected,
                            trailing: isCurrent
                                ? Container(
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AbTokens.space6,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: p.bgSurface,
                                      borderRadius: AbTokens.borderRadius3,
                                    ),
                                    child: Text(
                                      'current',
                                      style: AbTokens.sansStyle(
                                        fontSize: AbTokens.fontXs,
                                        height: 1.0,
                                        color: p.textMuted,
                                      ),
                                    ),
                                  )
                                : null,
                            onTap: () {
                              ref
                                  .read(newSessionBranchSelectionProvider.notifier)
                                  .set(NewSessionBranchSelection(
                                    targetId: target.id,
                                    branch: branch,
                                  ));
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
      error: (err, _) {
        return SizedBox(
          width: 280,
          child: Padding(
            padding: const EdgeInsets.all(AbTokens.space12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Branches unavailable',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontMd,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: AbTokens.space4),
                Text(
                  err.toString(),
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: p.textMuted,
                  ),
                ),
                const SizedBox(height: AbTokens.space8),
                Align(
                  alignment: Alignment.centerRight,
                  child: AbButton(
                    label: 'Retry',
                    compact: true,
                    onTap: () {
                      ref.invalidate(newSessionBranchCatalogProvider);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
      loading: () {
        return const SizedBox(
          width: 280,
          child: Padding(
            padding: EdgeInsets.all(AbTokens.space12),
            child: PanelHint('Loading branches…'),
          ),
        );
      },
    );
  }
}
