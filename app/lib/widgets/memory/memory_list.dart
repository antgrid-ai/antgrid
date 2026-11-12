import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/memory.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/memory.dart';
import 'memory_empty_state.dart';
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
    final t = CarbonTheme.of(context);
    final tag = memoryRowTag(record, projectRemoved: projectRemoved);
    final meta = memoryMetaLine(
      project: projectLabel,
      agent: agentLabel,
      created: record.createdAt,
    );
    return CarbonContainedListRow(
      // An activatable row hides its content from semantics, so the name has
      // to carry what the content shows: rows sharing a title differ only
      // there.
      title: [record.displayTitle, ?record.description, meta, ?tag].join('\n'),
      // A compact row opens a page rather than selecting, so it carries no
      // selected state.
      selected: compact ? null : selected,
      onPressed: onTap,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: CarbonSpacing.spacing02,
        children: [
          Text(
            record.displayTitle,
            maxLines: compact ? 3 : 2,
            overflow: TextOverflow.ellipsis,
            style: t.typography.body.copyWith(color: t.colors.textPrimary),
          ),
          if (record.description case final description?)
            Text(
              description,
              maxLines: compact ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              style: t.typography.helper.copyWith(
                color: t.colors.textSecondary,
              ),
            ),
          Wrap(
            spacing: CarbonSpacing.spacing03,
            runSpacing: CarbonSpacing.spacing02,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                meta,
                style: t.typography.helper.copyWith(color: t.colors.textHelper),
              ),
              if (tag != null) MemoryTag(label: tag),
            ],
          ),
        ],
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
    this.leading,
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

  /// Scrolls in above the rows, and above the loading, error and empty states
  /// too, so a notice is never stranded off the list.
  final Widget? leading;

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
    final first = widget.pages.first;
    final total = first.value?.total;
    final Widget? state = !first.hasValue && first.hasError
        ? _error(first.error!)
        : !first.hasValue
        ? const Center(child: CarbonLoading())
        : widget.visible.isEmpty && total == 0
        ? _empty()
        : null;
    final leading = widget.leading;
    if (state != null && leading == null) return state;

    // Every state keeps the one scroll view with the leading sliver first, so
    // the notices in it stay mounted across a reload rather than announcing
    // themselves again.
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (leading != null) SliverToBoxAdapter(child: leading),
        if (state != null)
          // Sized off the leading sliver's extent, which holds still while the
          // view scrolls; a floor keeps the state readable under tall notices.
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverToBoxAdapter(
              child: SizedBox(
                height: math.max(
                  constraints.viewportMainAxisExtent -
                      constraints.precedingScrollExtent,
                  CarbonSpacing.spacing13 * 2,
                ),
                child: state,
              ),
            ),
          )
        else
          ..._rows(total),
      ],
    );
  }

  List<Widget> _rows(int? total) {
    final labels = ref.watch(agentLabelsProvider);
    // The count header is a sliver, so it scrolls with the rows and the wheel
    // works across the whole pane. A compact list shows the count in the
    // toolbar instead.
    return [
      if (widget.compact)
        SliverList.builder(
          itemCount: widget.visible.length,
          itemBuilder: _row(labels),
        )
      else
        CarbonContainedListSliver(
          label: memoryCountLabel(total ?? widget.visible.length),
          itemCount: widget.visible.length,
          itemBuilder: _row(labels),
        ),
      SliverToBoxAdapter(child: _footer()),
    ];
  }

  IndexedWidgetBuilder _row(Map<String, String> labels) => (context, index) {
    final record = widget.visible[index];
    return MemoryListRow(
      record: record,
      projectLabel: widget.projects.labelFor(record.projectId),
      projectRemoved: widget.projects.isRemoved(record.projectId),
      agentLabel: memoryAgentName(record, labels),
      selected: record.id == widget.selectedId,
      onTap: () => widget.onSelect(record.id),
      compact: widget.compact,
    );
  };

  Widget _error(Object error) => Padding(
    padding: const EdgeInsets.all(CarbonSpacing.spacing05),
    child: CarbonNotification(
      kind: CarbonNotificationKind.error,
      subtitle: memoryErrorCopy(error),
      action: CarbonNotificationAction(
        label: 'Retry',
        onPressed: widget.onRetry,
      ),
    ),
  );

  Widget _footer() {
    final last = widget.pages.last;
    if (!last.hasValue) {
      if (last.hasError) return _error(last.error!);
      return const Padding(
        padding: EdgeInsets.all(CarbonSpacing.spacing05),
        child: Center(
          child: CarbonInlineLoading(status: CarbonInlineLoadingStatus.active),
        ),
      );
    }
    if (!last.requireValue.hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(CarbonSpacing.spacing04),
      child: CarbonButton(
        label: 'Show more',
        kind: CarbonButtonKind.ghost,
        expand: true,
        onPressed: widget.onShowMore,
      ),
    );
  }

  Widget _empty() {
    final filter = widget.filter;
    final earlier = filter.versions == MemoryVersions.earlier;
    final clear = CarbonButton(
      label: filter.isSearch || filter.memoryType != null
          ? 'Clear filters'
          : 'Show all projects',
      kind: CarbonButtonKind.tertiary,
      onPressed: widget.onClearFilters,
    );
    if (filter.isSearch || filter.memoryType != null) {
      return MemoryEmptyState(
        title: 'No memories match',
        subtitle: 'Try another word, or clear the project and kind filters.',
        action: clear,
      );
    }
    final projectId = filter.projectId;
    if (projectId != null) {
      final label = widget.projects.labelFor(projectId);
      return MemoryEmptyState(
        title: earlier
            ? 'No earlier versions for $label'
            : 'No memories for $label yet',
        subtitle: earlier
            ? 'When a memory is edited, its old text shows up here.'
            : 'Agents save memories here as they work in this project.',
        action: clear,
      );
    }
    return MemoryEmptyState(
      title: earlier ? 'No earlier versions' : 'No memories yet',
      subtitle: earlier
          ? 'When a memory is edited, its old text shows up here.'
          : 'Agents save memories here as they work.',
    );
  }
}
