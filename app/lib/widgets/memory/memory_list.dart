import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_scrollbar.dart';
import '../../models/memory.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/memory.dart';
import 'memory_error.dart';
import 'memory_format.dart';
import 'memory_tag.dart';

class MemoryListRow extends StatelessWidget {
  const MemoryListRow({
    super.key,
    required this.record,
    required this.projectLabel,
    required this.projectRemoved,
    required this.agentLabel,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final MemoryRecord record;
  final String projectLabel;
  final bool projectRemoved;
  final String agentLabel;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final tag = memoryRowTag(record, projectRemoved: projectRemoved);
    return Semantics(
      selected: selected,
      child: AbListRow(
        title: Text(
          record.content,
          style: AbTokens.sansStyle(
            fontSize: compact ? AbTokens.fontBody : AbTokens.fontMd,
            height: 1.45,
          ),
        ),
        titleMaxLines: compact ? 3 : 2,
        subtitle: Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              memoryMetaLine(
                project: projectLabel,
                agent: agentLabel,
                created: record.createdAt,
              ),
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: colors.textMuted,
              ),
            ),
            if (tag != null) MemoryTag(label: tag),
          ],
        ),
        subtitleMaxLines: 2,
        selected: selected,
        selectionStyle: AbRowSelection.surface,
        hoverable: true,
        divider: true,
        onTap: onTap,
      ),
    );
  }
}

/// A plain view over pages the screen already watched: it watches no page
/// provider, so a filter change never leaves it a frame behind its parent.
class MemoryListPane extends ConsumerStatefulWidget {
  const MemoryListPane({
    super.key,
    required this.filter,
    required this.pages,
    required this.visible,
    required this.selectedId,
    required this.onSelect,
    required this.onShowMore,
    required this.onClearFilters,
    required this.onRetry,
    required this.projects,
    this.compact = false,
  });

  final MemoryFilter filter;
  final List<AsyncValue<MemoryPage>> pages;
  final List<MemoryRecord> visible;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onShowMore;

  /// Resets query, project and kind, keeping the Current/Earlier choice. Also
  /// serves the project-only empty state, where that is "Show all projects".
  final VoidCallback onClearFilters;
  final VoidCallback onRetry;
  final MemoryProjects projects;
  final bool compact;

  @override
  ConsumerState<MemoryListPane> createState() => _MemoryListPaneState();
}

class _MemoryListPaneState extends ConsumerState<MemoryListPane> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final first = widget.pages.first;
    final total = first.value?.total;
    if (!first.hasValue && first.hasError) {
      return _error(first.error!);
    }
    if (!first.hasValue) return const Center(child: AbLoading());
    if (widget.visible.isEmpty && total == 0) return _empty();

    final catalog = ref.watch(agentCatalogProvider);
    final list = ListView.builder(
      controller: _scroll,
      itemCount: widget.visible.length + 1,
      itemBuilder: (context, index) {
        if (index == widget.visible.length) return _footer();
        final record = widget.visible[index];
        return MemoryListRow(
          record: record,
          projectLabel: widget.projects.labelFor(record.projectId),
          projectRemoved: widget.projects.isRemoved(record.projectId),
          agentLabel: memoryAgentName(record, catalog),
          selected: record.id == widget.selectedId,
          onTap: () => widget.onSelect(record.id),
          compact: widget.compact,
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.compact)
          Container(
            padding: const EdgeInsets.symmetric(
              vertical: AbTokens.space8,
              horizontal: AbTokens.space16,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            ),
            child: Text(
              memoryCountLabel(total ?? widget.visible.length),
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: colors.textMuted,
              ),
            ),
          ),
        Expanded(
          child: widget.compact
              ? list
              : AbScrollbar(controller: _scroll, child: list),
        ),
      ],
    );
  }

  Widget _error(Object error) => Padding(
    padding: const EdgeInsets.all(AbTokens.space16),
    child: AbInlineBanner(
      text: memoryErrorCopy(error),
      color: context.antgrid.error,
      footer: AbButton(label: 'Retry', compact: true, onTap: widget.onRetry),
    ),
  );

  Widget _footer() {
    final last = widget.pages.last;
    if (!last.hasValue) {
      if (last.hasError) return _error(last.error!);
      return const Padding(
        padding: EdgeInsets.all(AbTokens.space16),
        child: Center(child: AbLoading()),
      );
    }
    if (!last.requireValue.hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: AbButton(
        label: 'Show more',
        expand: true,
        onTap: widget.onShowMore,
      ),
    );
  }

  Widget _empty() {
    final filter = widget.filter;
    final earlier = filter.versions == MemoryVersions.earlier;
    final clear = AbButton(
      label: filter.isSearch || filter.memoryType != null
          ? 'Clear filters'
          : 'Show all projects',
      onTap: widget.onClearFilters,
    );
    if (filter.isSearch || filter.memoryType != null) {
      return AbEmptyState(
        title: 'No memories match',
        subtitle: 'Try another word, or clear the project and kind filters.',
        action: clear,
      );
    }
    final projectId = filter.projectId;
    if (projectId != null) {
      final label = widget.projects.labelFor(projectId);
      return AbEmptyState(
        title: earlier
            ? 'No earlier versions for $label'
            : 'No memories for $label yet',
        subtitle: earlier
            ? 'When a memory is edited, its old text shows up here.'
            : 'Agents save memories here as they work in this project.',
        action: clear,
      );
    }
    return AbEmptyState(
      title: earlier ? 'No earlier versions' : 'No memories yet',
      subtitle: earlier
          ? 'When a memory is edited, its old text shows up here.'
          : 'Agents save memories here as they work.',
    );
  }
}
