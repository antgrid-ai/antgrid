import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_scrollbar.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_switch.dart';
import '../../models/memory.dart';
import '../../providers/memory.dart';
import '../../util/detached.dart';
import '../../utils/platform_utils.dart';
import 'memory_error.dart';

Future<void> showMemorySettings(
  BuildContext context, {
  required MemoryTarget target,
  required Future<void> Function() onExportAll,
}) => showAbAdaptiveSheet<void>(
  context,
  maxWidth: 560,
  child: MemorySettingsDialog(target: target, onExportAll: onExportAll),
);

class MemorySettingsDialog extends ConsumerStatefulWidget {
  const MemorySettingsDialog({
    super.key,
    required this.target,
    required this.onExportAll,
  });

  final MemoryTarget target;
  final Future<void> Function() onExportAll;

  @override
  ConsumerState<MemorySettingsDialog> createState() =>
      _MemorySettingsDialogState();
}

class _MemorySettingsDialogState extends ConsumerState<MemorySettingsDialog> {
  final _scroll = ScrollController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _send(Map<String, dynamic> request) async {
    if (_busy) return false;
    final send = ref.read(memoryRequestProvider(widget.target));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await send(request);
      if (!mounted) return false;
      invalidateMemoryViews(ref, widget.target);
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = memoryErrorCopy(error, mutation: true));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: 'Turn off Memory?',
      body:
          'Agents stop saving and recalling memories. Everything saved stays on this machine, and you can turn Memory back on here.',
      confirmLabel: 'Turn off',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    if (await _send({'op': 'settings', 'enabled': false}) && mounted) {
      Navigator.of(context).pop();
    }
  }

  Widget _switchRow({
    required String title,
    String? description,
    String? state,
    required bool value,
    required String semanticLabel,
    required ValueChanged<bool>? onChanged,
    bool large = false,
  }) {
    final colors = context.antgrid;
    void toggle() => onChanged?.call(!value);
    final row = AbListRow(
      title: Text(
        title,
        style: AbTokens.sansStyle(
          fontSize: large ? AbTokens.fontBody : AbTokens.fontMd,
        ),
      ),
      subtitle: description == null
          ? null
          : Text(
              description,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontMd,
                color: colors.textSecondary,
              ),
            ),
      subtitleMaxLines: 3,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state != null) ...[
            Text(
              state,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: AbTokens.space8),
          ],
          ExcludeSemantics(
            child: AbSwitch(value: value, onChanged: onChanged),
          ),
        ],
      ),
      onTap: onChanged == null ? null : toggle,
    );
    return Semantics(
      toggled: value,
      label: semanticLabel,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : toggle,
      excludeSemantics: true,
      child: isMobilePlatform
          ? ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AbTokens.tapTargetMin),
              child: row,
            )
          : row,
    );
  }

  Widget _body(MemoryStatus? status, MemoryProjects? projects) {
    final colors = context.antgrid;
    final machinePaused = status?.paused ?? false;
    final live = [
      for (final p in projects?.projects ?? const <MemoryProjectSummary>[])
        if (!p.removed) p,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error case final error?) ...[
          AbInlineBanner(text: error, color: colors.error),
          const SizedBox(height: AbTokens.space16),
        ],
        if (status == null)
          const Center(child: AbLoading())
        else
          _switchRow(
            title: 'Let agents save memories',
            description:
                "When this is off, agents can still recall what's saved, and you can still edit and forget memories.",
            value: !status.paused,
            semanticLabel: 'Let agents save memories',
            large: true,
            onChanged: _busy
                ? null
                : (v) => detached(
                    'Memory',
                    'pause toggle failed',
                    () => _send({'op': 'settings', 'paused': !v}),
                  ),
          ),
        const SizedBox(height: AbTokens.space16),
        Text(
          'Saving by project',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            fontWeight: FontWeight.w600,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        if (machinePaused) ...[
          Text(
            'Saving is paused for every project.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space8),
        ],
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: colors.borderDefault),
            borderRadius: AbTokens.borderRadius5,
          ),
          child: projects == null
              ? const Padding(
                  padding: EdgeInsets.all(AbTokens.space12),
                  child: Center(child: AbLoading()),
                )
              : live.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AbTokens.space12),
                  child: Text(
                    'No projects yet.',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontMd,
                      color: colors.textMuted,
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (final (i, p) in live.indexed) ...[
                      if (i > 0) const AbSeparator.horizontal(),
                      _switchRow(
                        title: p.displayName,
                        state: machinePaused || p.paused ? 'Paused' : 'Saving',
                        value: !machinePaused && !p.paused,
                        semanticLabel: 'Saving for ${p.displayName}',
                        onChanged: _busy || machinePaused
                            ? null
                            : (v) => detached(
                                'Memory',
                                'project pause toggle failed',
                                () => _send({
                                  'op': 'settings',
                                  'project_id': p.projectId,
                                  'project_paused': !v,
                                }),
                              ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AbTokens.space16),
        Text(
          "Memories stay on this machine. Agents treat them as notes, not instructions: your repository's own docs always win.",
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(memoryStatusProvider(widget.target)).value;
    final projects = ref.watch(memoryProjectsProvider(widget.target)).value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.only(
            left: AbTokens.space16 + AbTokens.space4,
            right: AbTokens.space8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Memory settings',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontMd,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const AbSeparator.horizontal(),
        Flexible(
          child: AbScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(AbTokens.space16),
              child: _body(status, projects),
            ),
          ),
        ),
        const AbSeparator.horizontal(),
        Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: AbTokens.space8,
            runSpacing: AbTokens.space8,
            children: [
              AbButton(
                label: 'Export all memories',
                onTap: () {
                  final export = widget.onExportAll;
                  Navigator.of(context).pop();
                  detached('Memory', 'export failed', export);
                },
              ),
              AbButton(
                label: 'Turn off Memory',
                color: context.antgrid.error,
                onTap: _busy
                    ? null
                    : () => detached('Memory', 'turn off failed', _turnOff),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
