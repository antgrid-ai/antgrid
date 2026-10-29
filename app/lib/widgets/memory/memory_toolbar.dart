import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_search_field.dart';
import '../../design/widgets/ab_segmented.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/memory.dart';
import '../../util/detached.dart';

/// showAbMenu returns null on dismiss, so the "All" entries need a value of
/// their own to be told apart from a dismissed menu.
const _kAll = '*all*';

class MemoryToolbar extends StatelessWidget {
  const MemoryToolbar({
    super.key,
    required this.filter,
    required this.projects,
    required this.searchReady,
    required this.searchController,
    required this.onChanged,
    this.searchFocus,
    this.compact = false,
    this.countLine,
  });

  final MemoryFilter filter;
  final MemoryProjects? projects;
  final bool searchReady;
  final TextEditingController searchController;
  final ValueChanged<MemoryFilter> onChanged;
  final FocusNode? searchFocus;
  final bool compact;
  final String? countLine;

  MemoryFilter _with({
    String? query,
    MemoryVersions? versions,
    Object? projectId = _keep,
    Object? memoryType = _keep,
  }) => MemoryFilter(
    query: query ?? filter.query,
    versions: versions ?? filter.versions,
    projectId: identical(projectId, _keep)
        ? filter.projectId
        : projectId as String?,
    memoryType: identical(memoryType, _keep)
        ? filter.memoryType
        : memoryType as String?,
  );

  String get _projectLabel {
    final id = filter.projectId;
    if (id == null) return 'All projects';
    final name = projects?.labelFor(id) ?? id;
    return projects?.isRemoved(id) ?? false ? '$name (removed)' : name;
  }

  String get _kindLabel => filter.memoryType == null
      ? 'All kinds'
      : memoryKindLabel(filter.memoryType!);

  Future<void> _pickProject(BuildContext anchor) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final all = projects?.projects ?? const <MemoryProjectSummary>[];
    final live = all.where((p) => !p.removed);
    final removed = all.where((p) => p.removed);
    final current = filter.projectId;
    final picked = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      entries: [
        AbMenuItem(
          label: 'All projects',
          value: _kAll,
          icon: current == null ? AbIcons.check : null,
        ),
        for (final p in live)
          AbMenuItem(
            label: p.displayName,
            value: p.projectId,
            icon: current == p.projectId ? AbIcons.check : null,
          ),
        for (final p in removed)
          AbMenuItem(
            label: '${p.displayName} (removed)',
            value: p.projectId,
            icon: current == p.projectId ? AbIcons.check : null,
          ),
      ],
    );
    if (picked == null) return;
    onChanged(_with(projectId: picked == _kAll ? null : picked));
  }

  Future<void> _pickKind(BuildContext anchor) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final current = filter.memoryType;
    final picked = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      entries: [
        AbMenuItem(
          label: 'All kinds',
          value: _kAll,
          icon: current == null ? AbIcons.check : null,
        ),
        for (final kind in kMemoryKindOrder)
          AbMenuItem(
            label: memoryKindLabel(kind),
            value: kind,
            icon: current == kind ? AbIcons.check : null,
          ),
      ],
    );
    if (picked == null) return;
    onChanged(_with(memoryType: picked == _kAll ? null : picked));
  }

  Widget _picker(
    BuildContext context, {
    required String field,
    required String current,
    required Future<void> Function(BuildContext) open,
  }) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: AbTokens.space24 * (compact ? 6 : 8)),
    child: Builder(
      builder: (anchor) {
        void tap() =>
            detached('Memory', '$field menu failed', () => open(anchor));
        return Semantics(
          label: '$field: $current, change',
          button: true,
          excludeSemantics: true,
          onTap: tap,
          child: AbButton(
            label: current,
            maxLines: 1,
            wrapLabel: true,
            trailing: AbIcon(
              AbIcons.chevronDown,
              size: AbTokens.fontSm,
              color: context.antgrid.textMuted,
            ),
            onTap: tap,
          ),
        );
      },
    ),
  );

  Widget _search() {
    if (!searchReady) {
      return AbTextField(
        enabled: false,
        hintText: "Search is off until it's rebuilt",
        prefixIcon: AbIcons.search,
      );
    }
    return AbSearchField(
      controller: searchController,
      focusNode: searchFocus,
      hint: 'Search memories',
      debounce: const Duration(milliseconds: 250),
      height: compact ? AbTokens.rowHeightLg : AbTokens.rowHeightMd,
      onChanged: (text) {
        // A programmatic clear leaves the debounce pending; never apply text
        // the field no longer shows.
        if (text != searchController.text) return;
        onChanged(_with(query: text));
      },
    );
  }

  Widget _label(BuildContext context, String text) => ExcludeSemantics(
    child: Text(
      text,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        color: context.antgrid.textMuted,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final project = _picker(
      context,
      field: 'Project',
      current: _projectLabel,
      open: _pickProject,
    );
    final kind = _picker(
      context,
      field: 'Kind',
      current: _kindLabel,
      open: _pickKind,
    );
    if (!compact) {
      return Container(
        padding: const EdgeInsets.symmetric(
          vertical: AbTokens.space12,
          horizontal: AbTokens.space16,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.borderSubtle)),
        ),
        child: Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(width: AbTokens.space24 * 11, child: _search()),
            Semantics(
              label: 'Show',
              child: AbSegmented<MemoryVersions>(
                segments: const [
                  AbSegment(value: MemoryVersions.current, label: 'Current'),
                  AbSegment(
                    value: MemoryVersions.earlier,
                    label: 'Earlier versions',
                  ),
                ],
                selected: filter.versions,
                onSelect: (v) => onChanged(_with(versions: v)),
              ),
            ),
            _label(context, 'Project'),
            project,
            _label(context, 'Kind'),
            kind,
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        AbTokens.space8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _search(),
          const SizedBox(height: AbTokens.space10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                project,
                const SizedBox(width: AbTokens.space8),
                kind,
                const SizedBox(width: AbTokens.space8),
                AbChip.choice(
                  label: 'Earlier versions',
                  selected: filter.versions == MemoryVersions.earlier,
                  onTap: () => onChanged(
                    _with(
                      versions: filter.versions == MemoryVersions.earlier
                          ? MemoryVersions.current
                          : MemoryVersions.earlier,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (countLine case final line?) ...[
            const SizedBox(height: AbTokens.space10),
            Text(
              line,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

const Object _keep = Object();
