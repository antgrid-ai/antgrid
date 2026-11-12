import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/memory.dart';

/// The radio group reads a null value as "none selected", so the "All"
/// options need a value of their own to stay selectable.
const _kAll = '*all*';

const _searchOffCopy = "Search is off until it's rebuilt";

class MemoryToolbar extends StatelessWidget {
  const MemoryToolbar({
    super.key,
    required this.filter,
    required this.projects,
    required this.searchReady,
    required this.searchController,
    required this.onChanged,
    required this.onSearchChanged,
    required this.onSearchCleared,
    this.searchFocus,
    this.compact = false,
    this.countLine,
  });

  final MemoryFilter filter;
  final MemoryProjects projects;
  final bool searchReady;
  final TextEditingController searchController;

  /// Every filter edit except typing in the search field.
  final ValueChanged<MemoryFilter> onChanged;

  /// Raw search text, undebounced: the search field never debounces, so the
  /// owner of the query does.
  final ValueChanged<String> onSearchChanged;

  /// The clear button and Escape, which apply at once rather than waiting
  /// out the debounce.
  final VoidCallback onSearchCleared;
  final FocusNode? searchFocus;
  final bool compact;
  final String? countLine;

  String get _projectLabel {
    final id = filter.projectId;
    if (id == null) return 'All projects';
    return projects.stateLabelFor(id);
  }

  String get _kindLabel => filter.memoryType == null
      ? 'All kinds'
      : memoryKindLabel(filter.memoryType!);

  Widget _picker({
    required String field,
    required String current,
    required List<CarbonOption<String>> options,
    required String selected,
    required ValueChanged<String> onPicked,
  }) => ConstrainedBox(
    constraints: BoxConstraints(
      // On a phone the pickers split the row; on desktop a long project
      // name must not push the rest of the toolbar onto another line.
      maxWidth: compact ? double.infinity : CarbonSpacing.spacing06 * 8,
    ),
    child: CarbonMenuButton(
      label: current,
      kind: CarbonButtonKind.ghost,
      size: compact ? null : CarbonButtonSize.small,
      maxLines: 1,
      semanticLabel: field,
      triggerSemanticLabel: '$field: $current, change',
      entries: [
        CarbonMenuRadioGroup<String>(
          value: selected,
          options: options,
          onChanged: onPicked,
        ),
      ],
    ),
  );

  Widget _projectPicker() => _picker(
    field: 'Project',
    current: _projectLabel,
    selected: filter.projectId ?? _kAll,
    options: [
      const CarbonOption<String>(value: _kAll, label: 'All projects'),
      for (final p in projects.projects)
        CarbonOption<String>(value: p.projectId, label: p.stateLabel),
    ],
    onPicked: (picked) => onChanged(
      picked == _kAll
          ? filter.copyWith(clearProjectId: true)
          : filter.copyWith(projectId: picked),
    ),
  );

  Widget _kindPicker() => _picker(
    field: 'Kind',
    current: _kindLabel,
    selected: filter.memoryType ?? _kAll,
    options: [
      const CarbonOption<String>(value: _kAll, label: 'All kinds'),
      for (final kind in kMemoryKindOrder)
        CarbonOption<String>(value: kind, label: memoryKindLabel(kind)),
    ],
    onPicked: (picked) => onChanged(
      picked == _kAll
          ? filter.copyWith(clearMemoryType: true)
          : filter.copyWith(memoryType: picked),
    ),
  );

  Widget _search() {
    if (!searchReady) {
      // A disabled search paints its placeholder in the field colour, so the
      // problems strip above is what tells the user why.
      // Keyed apart from the live field: reusing its element would copy the
      // query into a field that no longer applies it.
      return const CarbonSearch(
        key: ValueKey('memory-search-off'),
        enabled: false,
        placeholder: _searchOffCopy,
        semanticLabel: _searchOffCopy,
      );
    }
    return CarbonSearch(
      key: const ValueKey('memory-search'),
      controller: searchController,
      focusNode: searchFocus,
      placeholder: 'Search memories',
      semanticLabel: 'Search memories',
      onChanged: onSearchChanged,
      onCleared: onSearchCleared,
    );
  }

  Widget _label(BuildContext context, String text) {
    final t = CarbonTheme.of(context);
    return ExcludeSemantics(
      child: Text(
        text,
        style: t.typography.label.copyWith(color: t.colors.textSecondary),
      ),
    );
  }

  /// The label shares the menu text's baseline: the two differ in size, so
  /// centring them leaves the smaller label sitting low.
  Widget _field(BuildContext context, String label, Widget picker) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [_label(context, label), picker],
  );

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final rule = BoxDecoration(
      border: Border(bottom: BorderSide(color: t.borderSubtle(1))),
    );
    if (!compact) {
      return DecoratedBox(
        decoration: rule,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: CarbonSpacing.spacing04,
            horizontal: CarbonSpacing.spacing05,
          ),
          child: Wrap(
            spacing: CarbonSpacing.spacing03,
            runSpacing: CarbonSpacing.spacing03,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(width: CarbonSpacing.spacing06 * 11, child: _search()),
              CarbonContentSwitcher<MemoryVersions>(
                size: CarbonContentSwitcherSize.small,
                semanticLabel: 'Show',
                options: const [
                  CarbonOption(value: MemoryVersions.current, label: 'Current'),
                  CarbonOption(
                    value: MemoryVersions.earlier,
                    label: 'Earlier versions',
                  ),
                ],
                value: filter.versions,
                onChanged: (v) => onChanged(filter.copyWith(versions: v)),
              ),
              _field(context, 'Project', _projectPicker()),
              _field(context, 'Kind', _kindPicker()),
            ],
          ),
        ),
      );
    }
    final earlier = filter.versions == MemoryVersions.earlier;
    return DecoratedBox(
      decoration: rule,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CarbonSpacing.spacing05,
          CarbonSpacing.spacing04,
          CarbonSpacing.spacing05,
          CarbonSpacing.spacing03,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _search(),
            const SizedBox(height: CarbonSpacing.spacing03),
            Row(
              spacing: CarbonSpacing.spacing03,
              children: [
                Expanded(child: _projectPicker()),
                Expanded(child: _kindPicker()),
              ],
            ),
            const SizedBox(height: CarbonSpacing.spacing02),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CarbonTag(
                label: 'Earlier versions',
                selected: earlier,
                onSelectedChanged: (on) => onChanged(
                  filter.copyWith(
                    versions: on
                        ? MemoryVersions.earlier
                        : MemoryVersions.current,
                  ),
                ),
              ),
            ),
            if (countLine case final line?) ...[
              const SizedBox(height: CarbonSpacing.spacing03),
              Text(
                line,
                style: t.typography.helper.copyWith(
                  color: t.colors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
